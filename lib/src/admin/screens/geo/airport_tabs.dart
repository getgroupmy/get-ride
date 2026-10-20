// Admin → Airport Areas, one airport's editor (migration 0249): the Gates &
// doors, Pickup rules, Waiting queue, Fares and Charges tabs, and a pickup
// door's guide. Each takes the airport's settings and hands changes back;
// airport_editor.dart reads and saves them.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/airport_queue.dart';
import '../../../core/format.dart';
import '../../../data/airport_repository.dart'
    show AirportZone, zoneSourceLabel;
import '../../../widgets/search_select.dart';
import '../../../widgets/storage_image.dart';

const _gap = SizedBox(height: 12);

/// A row with a title, a line under it and a control on the right.
class AirportRow extends StatelessWidget {
  const AirportRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.textTheme.bodyLarge),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: t.textTheme.bodySmall?.copyWith(
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A switch row.
class AirportSwitch extends StatelessWidget {
  const AirportSwitch({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => AirportRow(
    title: title,
    subtitle: subtitle,
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

/// A shaded note.
class AirportNote extends StatelessWidget {
  const AirportNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: t.textTheme.bodySmall?.copyWith(height: 1.45)),
    );
  }
}

/// − value + with limits.
class AirportStepper extends StatelessWidget {
  const AirportStepper({
    super.key,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    this.step = 1,
    this.onChanged,
    this.label = '',
  });
  final int value, min, max, step;
  final String unit, label;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          tooltip: 'Lower $label'.trim(),
          onPressed: on == null || value <= min
              ? null
              : () => on((value - step).clamp(min, max)),
          icon: const Icon(Icons.remove, size: 18),
        ),
        SizedBox(
          width: 64,
          child: Text(
            '$value $unit',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        IconButton.filledTonal(
          tooltip: 'Raise $label'.trim(),
          onPressed: on == null || value >= max
              ? null
              : () => on((value + step).clamp(min, max)),
          icon: const Icon(Icons.add, size: 18),
        ),
      ],
    );
  }
}

/// A number field that keeps its text while typed and hands back the
/// number (0 for blank).
class AmountField extends StatefulWidget {
  const AmountField({
    super.key,
    required this.value,
    required this.label,
    this.onChanged,
    this.width = 120,
    this.decimals = 2,
  });
  final double value;
  final String label;
  final ValueChanged<double>? onChanged;
  final double width;
  final int decimals;

  @override
  State<AmountField> createState() => _AmountFieldState();
}

class _AmountFieldState extends State<AmountField> {
  late final _c = TextEditingController(text: _fmt(widget.value));

  String _fmt(double v) => widget.decimals == 0
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(widget.decimals);

  @override
  void didUpdateWidget(AmountField old) {
    super.didUpdateWidget(old);
    final typed = double.tryParse(_c.text.trim());
    if (typed != widget.value && old.value != widget.value) {
      _c.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    child: TextField(
      controller: _c,
      enabled: widget.onChanged != null,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: InputDecoration(labelText: widget.label, isDense: true),
      onChanged: (v) {
        final n = double.tryParse(v.trim());
        widget.onChanged?.call(n == null || !n.isFinite || n < 0 ? 0 : n);
      },
    ),
  );
}

/// A text field that hands back what is typed.
class NameField extends StatefulWidget {
  const NameField({
    super.key,
    required this.value,
    required this.label,
    this.onChanged,
  });
  final String value, label;
  final ValueChanged<String>? onChanged;

  @override
  State<NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<NameField> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    enabled: widget.onChanged != null,
    maxLength: 60,
    decoration: InputDecoration(
      labelText: widget.label,
      isDense: true,
      counterText: '',
    ),
    onChanged: widget.onChanged,
  );
}

Widget _section(
  BuildContext context, {
  required List<Widget> children,
  Key? key,
}) => Card(
  key: key,
  margin: const EdgeInsets.only(bottom: 12),
  child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  ),
);

Widget _sourceChip(BuildContext context, String source) {
  final t = Theme.of(context);
  return Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: t.colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      zoneSourceLabel(source),
      style: t.textTheme.labelSmall?.copyWith(
        color: t.colorScheme.onSecondaryContainer,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Gates & doors
// ---------------------------------------------------------------------------

class AirportDoorsTab extends StatelessWidget {
  const AirportDoorsTab({
    super.key,
    required this.doors,
    required this.settings,
    required this.onSettings,
    this.onKind,
    this.onRemove,
    this.onMove,
    this.onAdd,
    this.onRename,
    this.onGuide,
    this.openGuideId,
    this.guideEditor,
  });

  final List<AirportDoor> doors;
  final AirportSettings settings;
  final ValueChanged<AirportSettings>? onSettings;
  final void Function(AirportDoor door, DoorKind kind)? onKind;
  final void Function(AirportDoor door)? onRemove, onRename, onGuide;
  final void Function(AirportDoor door, int dir)? onMove;
  final VoidCallback? onAdd;
  final String? openGuideId;
  final Widget? guideEditor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edit = onSettings != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const AirportNote(
          "These are the same doors as on the Multi-Gate page. Adding, renaming, removing or changing a door's use "
          'here changes it there too, and the reverse.',
        ),
        _gap,
        if (doors.isEmpty) Text('No doors yet.', style: t.textTheme.bodySmall),
        ListSearchFilter(
          count: doors.length,
          hint: 'Search doors',
          builder: (context, q) => Column(
            children: [
              for (var i = 0; i < doors.length; i++)
                if (q.isEmpty || searchSelectMatches(doors[i].name, q))
                  _door(context, i, edit),
            ],
          ),
        ),
        if (onAdd != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('airport-add-door'),
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add door'),
            ),
          ),
        _gap,
        AirportSwitch(
          title: 'Rider must pick a drop-off door',
          subtitle: 'When going to the airport; only drop-off doors are listed',
          value: settings.dropDoorRequired,
          onChanged: edit
              ? (v) => onSettings!(settings.copyWith(dropDoorRequired: v))
              : null,
        ),
        AirportSwitch(
          title: 'Rider must pick a pickup door',
          subtitle: 'When leaving the airport; only pickup doors are listed',
          value: settings.pickDoorRequired,
          onChanged: edit
              ? (v) => onSettings!(settings.copyWith(pickDoorRequired: v))
              : null,
        ),
        if (guideEditor != null) ...[const Divider(height: 32), guideEditor!],
      ],
    );
  }

  Widget _door(BuildContext context, int i, bool edit) {
    final t = Theme.of(context);
    final d = doors[i];
    final pick = d.kind != DoorKind.drop;
    return Card(
      key: ValueKey('airport-door-row-${d.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${i + 1}. ${d.name}',
                    style: t.textTheme.bodyLarge,
                  ),
                ),
                Text(
                  'Synced',
                  style: t.textTheme.labelSmall?.copyWith(
                    color: t.colorScheme.primary,
                  ),
                ),
                if (onMove != null) ...[
                  IconButton(
                    tooltip: 'Move up',
                    onPressed: i == 0 ? null : () => onMove!(d, -1),
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: 'Move down',
                    onPressed: i == doors.length - 1
                        ? null
                        : () => onMove!(d, 1),
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ],
                if (onRename != null)
                  IconButton(
                    tooltip: 'Rename',
                    onPressed: () => onRename!(d),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: () => onRemove!(d),
                    icon: Icon(
                      Icons.delete_outline,
                      color: t.colorScheme.error,
                    ),
                  ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final k in DoorKind.values)
                  ChoiceChip(
                    key: ValueKey('airport-door-kind-${d.id}-${k.name}'),
                    label: Text(doorKindLabel(k)),
                    selected: d.kind == k,
                    onSelected: onKind == null ? null : (_) => onKind!(d, k),
                  ),
              ],
            ),
            if (pick && onGuide != null)
              TextButton(
                key: ValueKey('airport-door-guide-${d.id}'),
                onPressed: () => onGuide!(d),
                child: Text(
                  d.guide.isEmpty
                      ? '+ Add a how-to guide'
                      : 'How-to guide · ${d.guide.length} step${d.guide.length == 1 ? '' : 's'} · ${openGuideId == d.id ? 'Open' : 'Edit'}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A pickup door's guide: steps with a photo and a short instruction.
class AirportGuideEditor extends StatelessWidget {
  const AirportGuideEditor({
    super.key,
    required this.door,
    required this.onChanged,
    this.onPhoto,
    this.onPreview,
    this.onClose,
    this.busyStep,
  });

  final AirportDoor door;
  final ValueChanged<List<GuideStep>>? onChanged;

  /// Upload or replace the photo of step i.
  final void Function(int i)? onPhoto;
  final VoidCallback? onPreview, onClose;
  final int? busyStep;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final steps = door.guide;
    final edit = onChanged != null;
    return Column(
      key: const ValueKey('airport-guide-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'How to reach ${door.name}',
                style: t.textTheme.titleMedium,
              ),
            ),
            if (onPreview != null)
              TextButton(
                key: const ValueKey('airport-guide-preview'),
                onPressed: onPreview,
                child: const Text('Preview as rider'),
              ),
            if (onClose != null)
              TextButton(onPressed: onClose, child: const Text('Close')),
          ],
        ),
        Text(
          'Riders see these steps in order after picking this pickup door. Each step has a photo and a short '
          'instruction. Tap a photo box to add or change the photo.',
          style: t.textTheme.bodySmall?.copyWith(
            color: t.colorScheme.onSurfaceVariant,
          ),
        ),
        _gap,
        if (steps.isEmpty) Text('No steps yet.', style: t.textTheme.bodySmall),
        for (var i = 0; i < steps.length; i++) _step(context, i, edit),
        if (edit && steps.length < maxGuideSteps)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('airport-guide-add-step'),
              onPressed: () => onChanged!([...steps, const GuideStep()]),
              icon: const Icon(Icons.add),
              label: const Text('Add step'),
            ),
          ),
      ],
    );
  }

  Widget _step(BuildContext context, int i, bool edit) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final steps = door.guide;
    final s = steps[i];
    final thumb = SizedBox(
      width: 120,
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Material(
          color: scheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('airport-guide-photo-$i'),
            onTap: onPhoto == null ? null : () => onPhoto!(i),
            child: busyStep == i
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : s.photo == null
                ? Center(
                    child: Text(
                      '+ Add photo',
                      style: TextStyle(color: scheme.primary),
                    ),
                  )
                : StorageImage(
                    s.photo!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                  ),
          ),
        ),
      ),
    );
    final text = _StepText(
      key: ValueKey('airport-guide-text-$i-${steps.length}'),
      value: s.text,
      label: 'Instruction for step ${i + 1}',
      onChanged: edit
          ? (v) => onChanged!([
              for (var k = 0; k < steps.length; k++)
                k == i ? steps[k].copyWith(text: v) : steps[k],
            ])
          : null,
    );
    final controls = Wrap(
      direction: Axis.vertical,
      children: [
        IconButton(
          tooltip: 'Move step ${i + 1} up',
          onPressed: !edit || i == 0
              ? null
              : () => onChanged!(moveStep(steps, i, -1)),
          icon: const Icon(Icons.arrow_upward, size: 18),
        ),
        IconButton(
          tooltip: 'Move step ${i + 1} down',
          onPressed: !edit || i == steps.length - 1
              ? null
              : () => onChanged!(moveStep(steps, i, 1)),
          icon: const Icon(Icons.arrow_downward, size: 18),
        ),
        IconButton(
          tooltip: 'Delete step ${i + 1}',
          onPressed: !edit ? null : () => onChanged!([...steps]..removeAt(i)),
          icon: Icon(Icons.close, size: 18, color: scheme.error),
        ),
      ],
    );
    final number = CircleAvatar(
      radius: 13,
      backgroundColor: scheme.tertiary,
      child: Text(
        '${i + 1}',
        style: TextStyle(
          color: scheme.onTertiary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return Card(
      key: ValueKey('airport-guide-step-$i'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (_, c) => c.maxWidth < 460
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    number,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [thumb, const SizedBox(height: 8), text],
                      ),
                    ),
                    controls,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    number,
                    const SizedBox(width: 10),
                    thumb,
                    const SizedBox(width: 10),
                    Expanded(child: text),
                    controls,
                  ],
                ),
        ),
      ),
    );
  }
}

class _StepText extends StatefulWidget {
  const _StepText({
    super.key,
    required this.value,
    required this.label,
    this.onChanged,
  });
  final String value, label;
  final ValueChanged<String>? onChanged;

  @override
  State<_StepText> createState() => _StepTextState();
}

class _StepTextState extends State<_StepText> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_StepText old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text && old.value != widget.value) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    enabled: widget.onChanged != null,
    minLines: 2,
    maxLines: 4,
    maxLength: maxGuideText,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: 'e.g. Take the escalator down to Level 1',
      counterText: '',
      border: const OutlineInputBorder(),
    ),
    onChanged: widget.onChanged,
  );
}

// ---------------------------------------------------------------------------
// Pickup rules
// ---------------------------------------------------------------------------

class AirportRulesTab extends StatelessWidget {
  const AirportRulesTab({super.key, required this.settings, this.onChanged});
  final AirportSettings settings;
  final ValueChanged<AirportSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = settings;
    final on = onChanged;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AirportSwitch(
          title: 'Restrict pickups inside the airport',
          subtitle: 'Off: any nearby driver gets airport pickups, as today',
          value: s.restrictPickups,
          onChanged: on == null
              ? null
              : (v) => on(s.copyWith(restrictPickups: v)),
        ),
        if (s.restrictPickups) ...[
          _gap,
          Text(
            'Who gets a pickup inside the airport (pick one or both)',
            style: t.textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                key: const ValueKey('airport-from-queue'),
                label: const Text('Drivers in the waiting queue'),
                selected: s.pickupFrom.contains(PickupSource.queue),
                onSelected: on == null
                    ? null
                    : (_) => on(
                        s.copyWith(
                          pickupFrom: togglePickupSource(
                            s.pickupFrom,
                            PickupSource.queue,
                          ),
                        ),
                      ),
              ),
              FilterChip(
                key: const ValueKey('airport-from-zone'),
                label: const Text('Any driver inside a waiting zone'),
                selected: s.pickupFrom.contains(PickupSource.zone),
                onSelected: on == null
                    ? null
                    : (_) => on(
                        s.copyWith(
                          pickupFrom: togglePickupSource(
                            s.pickupFrom,
                            PickupSource.zone,
                          ),
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(pickupSourceSummary(s.pickupFrom), style: t.textTheme.bodySmall),
          _gap,
          Text(
            'If nobody is in the queue or zone',
            style: t.textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (a, label) in const [
                (EmptyAction.wait, 'Wait for a driver'),
                (EmptyAction.decline, 'Decline the request'),
                (EmptyAction.nearby, 'Send to nearby drivers'),
              ])
                ChoiceChip(
                  key: ValueKey('airport-empty-${a.name}'),
                  label: Text(label),
                  selected: s.emptyAction == a,
                  onSelected: on == null
                      ? null
                      : (_) => on(s.copyWith(emptyAction: a)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(emptyActionSummary(s.emptyAction), style: t.textTheme.bodySmall),
          if (s.emptyAction == EmptyAction.nearby)
            AirportRow(
              title: 'Send to nearby drivers after',
              subtitle: '0 = straight away',
              trailing: AirportStepper(
                key: const ValueKey('airport-nearby-min'),
                value: s.nearbyAfterMin,
                unit: 'min',
                min: 0,
                max: 120,
                label: 'nearby wait',
                onChanged: on == null
                    ? null
                    : (v) => on(s.copyWith(nearbyAfterMin: v)),
              ),
            ),
          _gap,
          const AirportRow(
            title: 'Drivers around the airport',
            subtitle:
                "Drivers inside the area but outside a waiting zone don't get airport pickups, and see "
                '"Go to the waiting zone to receive airport orders"',
          ),
          _gap,
          const AirportNote(
            'Drop-offs at the airport work as usual for every driver.',
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Waiting queue
// ---------------------------------------------------------------------------

class AirportQueueTab extends StatelessWidget {
  const AirportQueueTab({
    super.key,
    required this.settings,
    required this.zones,
    this.onChanged,
    this.onAddZone,
    this.onEditZone,
    this.onRemoveZone,
    this.map,
    this.services = const [],
    this.serviceOrder = const ServiceOrder([]),
    this.onServiceOrder,
  });
  final AirportSettings settings;
  final List<AirportZone> zones;

  /// Every vehicle service (id, name), and their order lowest first.
  final List<({String id, String name})> services;
  final ServiceOrder serviceOrder;
  final ValueChanged<ServiceOrder>? onServiceOrder;
  final ValueChanged<AirportSettings>? onChanged;
  final VoidCallback? onAddZone;
  final void Function(AirportZone z)? onEditZone, onRemoveZone;
  final Widget? map;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = settings;
    final on = onChanged;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ?map,
        if (map != null) _gap,
        Text('Waiting zones (one or more)', style: t.textTheme.labelLarge),
        const SizedBox(height: 6),
        if (zones.isEmpty)
          Text('No waiting zones yet.', style: t.textTheme.bodySmall),
        for (final z in zones)
          Card(
            key: ValueKey('airport-wait-zone-${z.id}'),
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              title: Row(
                children: [
                  Flexible(child: Text(z.name)),
                  _sourceChip(context, z.source),
                ],
              ),
              subtitle: const Text('Drawn on the map'),
              trailing: Wrap(
                children: [
                  if (onEditZone != null)
                    IconButton(
                      tooltip: 'Edit outline',
                      onPressed: () => onEditZone!(z),
                      icon: const Icon(Icons.map_outlined),
                    ),
                  if (onRemoveZone != null)
                    IconButton(
                      tooltip: 'Remove',
                      onPressed: () => onRemoveZone!(z),
                      icon: Icon(
                        Icons.delete_outline,
                        color: t.colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (onAddZone != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('airport-add-wait-zone'),
              onPressed: onAddZone,
              icon: const Icon(Icons.add),
              label: const Text('Add waiting zone'),
            ),
          ),
        _gap,
        AirportSwitch(
          title: 'Queue by service type',
          subtitle: 'One line per service, e.g. Comfort riders go to the first Comfort driver',
          value: s.queueByService,
          onChanged: on == null
              ? null
              : (v) => on(s.copyWith(queueByService: v)),
        ),
        AirportSwitch(
          title: 'Only drivers who dropped off here can join',
          subtitle:
              "A driver with no drop-off at this airport can't enter the queue",
          value: s.needDropoff,
          onChanged: on == null ? null : (v) => on(s.copyWith(needDropoff: v)),
        ),
        AirportRow(
          title: 'Join within',
          subtitle: 'Time after the drop-off to reach a waiting zone',
          trailing: AirportStepper(
            key: const ValueKey('airport-window'),
            value: s.joinWindowMin,
            unit: 'min',
            min: 15,
            max: 720,
            step: 15,
            label: 'join window',
            onChanged: on == null
                ? null
                : (v) => on(s.copyWith(joinWindowMin: v)),
          ),
        ),
        AirportRow(
          title: 'Leaving the zone',
          subtitle:
              'A driver who leaves for longer than this loses their place',
          trailing: AirportStepper(
            key: const ValueKey('airport-grace'),
            value: s.leaveGraceMin,
            unit: 'min',
            min: 0,
            max: 60,
            label: 'grace',
            onChanged: on == null
                ? null
                : (v) => on(s.copyWith(leaveGraceMin: v)),
          ),
        ),
        AirportRow(
          title: 'Time to answer an offer',
          subtitle: 'Then the next driver in the queue gets it',
          trailing: AirportStepper(
            key: const ValueKey('airport-offer-seconds'),
            value: s.offerSeconds,
            unit: 's',
            min: 10,
            max: 300,
            step: 5,
            label: 'answer time',
            onChanged: on == null
                ? null
                : (v) => on(s.copyWith(offerSeconds: v)),
          ),
        ),
        AirportSwitch(
          title: 'A declined or missed offer sends the driver to the back',
          subtitle: 'Off: the driver keeps their place',
          value: s.backOnDecline,
          onChanged: on == null
              ? null
              : (v) => on(s.copyWith(backOnDecline: v)),
        ),
        _gap,
        const AirportNote(
          'Order: the earliest drop-off goes first, and one drop-off gives one place.',
        ),
        _gap,
        ServiceOrderEditor(
          services: services,
          order: serviceOrder,
          onChanged: onServiceOrder,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fares
// ---------------------------------------------------------------------------

/// The admin's "Try a fare" inputs.
class FareTrial {
  const FareTrial({
    this.service = '',
    this.side = AirportSide.pick,
    this.zoneId,
    this.km = 12,
    this.perKm = 1.75,
    this.normal = 30,
  });
  final String service;
  final AirportSide side;
  final String? zoneId;
  final double km, perKm, normal;

  FareTrial copyWith({
    String? service,
    AirportSide? side,
    String? zoneId,
    bool byDistance = false,
    double? km,
    double? perKm,
    double? normal,
  }) => FareTrial(
    service: service ?? this.service,
    side: side ?? this.side,
    zoneId: byDistance ? null : (zoneId ?? this.zoneId),
    km: km ?? this.km,
    perKm: perKm ?? this.perKm,
    normal: normal ?? this.normal,
  );
}

class AirportFaresTab extends StatefulWidget {
  const AirportFaresTab({
    super.key,
    required this.settings,
    required this.services,
    required this.zones,
    this.onChanged,
    this.onAddZone,
    this.onEditZone,
    this.onRemoveZone,
    this.onZoneAmounts,
    this.currency = 'MYR',
  });
  final AirportSettings settings;
  final List<String> services;
  final List<AirportZone> zones;
  final ValueChanged<AirportSettings>? onChanged;
  final VoidCallback? onAddZone;
  final void Function(AirportZone z)? onEditZone, onRemoveZone;
  final void Function(AirportZone z, double to, double from)? onZoneAmounts;
  final String currency;

  @override
  State<AirportFaresTab> createState() => _AirportFaresTabState();
}

class _AirportFaresTabState extends State<AirportFaresTab> {
  late FareTrial _trial = FareTrial(
    service: widget.services.isEmpty ? 'Ride' : widget.services.first,
  );

  AirportFares get _f => widget.settings.fares;

  void _set(AirportFares f) =>
      widget.onChanged?.call(widget.settings.copyWith(fares: f));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _f;
    final edit = widget.onChanged != null;
    String money(double v) => formatMoney(v, widget.currency);
    final band = f.band;
    final tiers = band.sorted;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const AirportNote(
          'Fares for rides to and from this airport. They replace the normal fare for these rides only. '
          "Every amount below is on top of the service's airport base.",
        ),
        _gap,
        _section(
          context,
          key: const ValueKey('airport-fares-base'),
          children: [
            Text('Airport base by service', style: t.textTheme.titleSmall),
            Text(
              'Added to every airport fare of that service, e.g. Premium costs more than Ride for the same trip',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            ListSearchFilter(
              count: widget.services.length,
              hint: 'Search services',
              fieldKey: const ValueKey('airport-base-search'),
              builder: (context, q) => Column(
                children: [
                  for (final sv in widget.services)
                    if (q.isEmpty || searchSelectMatches(sv, q))
                      AirportRow(
                        title: sv,
                        trailing: AmountField(
                          key: ValueKey('airport-base-$sv'),
                          value: f.baseFor(sv),
                          label: 'Base',
                          onChanged: edit
                              ? (v) => _set(
                                  f.copyWith(
                                    base: {
                                      ...f.base,
                                      sv.trim().toLowerCase(): v,
                                    },
                                  ),
                                )
                              : null,
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
        _section(
          context,
          children: [
            Text('Minimum fare', style: t.textTheme.titleSmall),
            Text(
              'A cheaper fare is raised to this (before the airport charges)',
              style: t.textTheme.bodySmall,
            ),
            for (final (pick, label) in const [
              (true, 'Pickup from the airport'),
              (false, 'Drop-off at the airport'),
            ])
              AirportRow(
                title: label,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ((pick ? f.minPick : f.minDrop).on)
                      AmountField(
                        key: ValueKey('airport-min-${pick ? 'pick' : 'drop'}'),
                        value: (pick ? f.minPick : f.minDrop).amount,
                        label: 'Minimum',
                        width: 100,
                        onChanged: edit
                            ? (v) => _set(
                                pick
                                    ? f.copyWith(
                                        minPick: MinFare(on: true, amount: v),
                                      )
                                    : f.copyWith(
                                        minDrop: MinFare(on: true, amount: v),
                                      ),
                              )
                            : null,
                      ),
                    Switch(
                      value: (pick ? f.minPick : f.minDrop).on,
                      onChanged: edit
                          ? (v) {
                              final cur = pick ? f.minPick : f.minDrop;
                              final next = MinFare(
                                on: v,
                                amount: v && cur.amount <= 0 ? 30 : cur.amount,
                              );
                              _set(
                                pick
                                    ? f.copyWith(minPick: next)
                                    : f.copyWith(minDrop: next),
                              );
                            }
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
        _section(
          context,
          key: const ValueKey('airport-fares-band'),
          children: [
            AirportSwitch(
              title: 'Distance bands',
              subtitle: 'Flat fares by distance; past the last band, its flat fare plus the normal rate',
              value: band.on,
              onChanged: edit
                  ? (v) => _set(f.copyWith(band: band.copyWith(on: v)))
                  : null,
            ),
            if (band.on) ...[
              for (var i = 0; i < tiers.length; i++)
                Padding(
                  key: ValueKey('airport-band-tier-$i'),
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Text('${i == 0 ? '0' : _km(tiers[i - 1].uptoKm)} to'),
                      AmountField(
                        key: ValueKey('airport-band-km-$i-${tiers.length}'),
                        value: tiers[i].uptoKm,
                        label: 'km',
                        width: 80,
                        decimals: 0,
                        onChanged: edit
                            ? (v) => _set(
                                f.copyWith(
                                  band: band.copyWith(
                                    tiers: [
                                      for (var k = 0; k < tiers.length; k++)
                                        k == i
                                            ? BandTier(
                                                uptoKm: v,
                                                flat: tiers[k].flat,
                                              )
                                            : tiers[k],
                                    ],
                                  ),
                                ),
                              )
                            : null,
                      ),
                      const Text('km ·'),
                      AmountField(
                        key: ValueKey('airport-band-flat-$i-${tiers.length}'),
                        value: tiers[i].flat,
                        label: 'Flat fare',
                        width: 100,
                        onChanged: edit
                            ? (v) => _set(
                                f.copyWith(
                                  band: band.copyWith(
                                    tiers: [
                                      for (var k = 0; k < tiers.length; k++)
                                        k == i
                                            ? BandTier(
                                                uptoKm: tiers[k].uptoKm,
                                                flat: v,
                                              )
                                            : tiers[k],
                                    ],
                                  ),
                                ),
                              )
                            : null,
                      ),
                      if (edit && tiers.length > 1)
                        TextButton(
                          key: ValueKey('airport-band-remove-$i'),
                          onPressed: () => _set(
                            f.copyWith(
                              band: band.copyWith(
                                tiers: removeBandTier(tiers, i),
                              ),
                            ),
                          ),
                          child: const Text('Remove'),
                        ),
                    ],
                  ),
                ),
              if (bandTiersProblem(tiers) case final p?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(p, style: TextStyle(color: t.colorScheme.error)),
                ),
              if (edit)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('airport-band-add'),
                    onPressed: () => _set(
                      f.copyWith(
                        band: band.copyWith(tiers: addBandTier(tiers)),
                      ),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Add band'),
                  ),
                ),
              Text(
                'More than ${_km(tiers.last.uptoKm)} km: ${money(tiers.last.flat)} + the normal rate for',
                style: t.textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const ValueKey('airport-band-extra'),
                    label: Text(
                      'only the km past ${_km(tiers.last.uptoKm)} km',
                    ),
                    selected: band.extra == BandExtra.extra,
                    onSelected: edit
                        ? (_) => _set(
                            f.copyWith(
                              band: band.copyWith(extra: BandExtra.extra),
                            ),
                          )
                        : null,
                  ),
                  ChoiceChip(
                    key: const ValueKey('airport-band-all'),
                    label: const Text('the whole trip'),
                    selected: band.extra == BandExtra.all,
                    onSelected: edit
                        ? (_) => _set(
                            f.copyWith(
                              band: band.copyWith(extra: BandExtra.all),
                            ),
                          )
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Applies to', style: t.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (a, label) in const [
                    (BandApplies.both, 'Pickup and drop-off'),
                    (BandApplies.pick, 'Pickup only'),
                    (BandApplies.drop, 'Drop-off only'),
                  ])
                    ChoiceChip(
                      key: ValueKey('airport-band-applies-${a.name}'),
                      label: Text(label),
                      selected: band.applies == a,
                      onSelected: edit
                          ? (_) => _set(
                              f.copyWith(band: band.copyWith(applies: a)),
                            )
                          : null,
                    ),
                ],
              ),
            ],
          ],
        ),
        _section(
          context,
          key: const ValueKey('airport-fares-zones'),
          children: [
            Text('Fixed zone fares', style: t.textTheme.titleSmall),
            Text(
              'A ride between a zone and the airport costs this fixed fare instead of the band or normal rate.',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            if (widget.zones.isEmpty)
              Text('No zones yet.', style: t.textTheme.bodySmall),
            for (final z in widget.zones)
              Padding(
                key: ValueKey('airport-fare-zone-${z.id}'),
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    SizedBox(
                      width: 200,
                      child: Row(
                        children: [
                          Flexible(child: Text(z.name)),
                          _sourceChip(context, z.source),
                        ],
                      ),
                    ),
                    AmountField(
                      value: z.toAmount,
                      label: 'To airport',
                      width: 100,
                      onChanged: widget.onZoneAmounts == null
                          ? null
                          : (v) => widget.onZoneAmounts!(z, v, z.fromAmount),
                    ),
                    AmountField(
                      value: z.fromAmount,
                      label: 'From airport',
                      width: 100,
                      onChanged: widget.onZoneAmounts == null
                          ? null
                          : (v) => widget.onZoneAmounts!(z, z.toAmount, v),
                    ),
                    if (widget.onEditZone != null)
                      IconButton(
                        tooltip: 'Edit outline',
                        onPressed: () => widget.onEditZone!(z),
                        icon: const Icon(Icons.map_outlined),
                      ),
                    if (widget.onRemoveZone != null)
                      TextButton(
                        onPressed: () => widget.onRemoveZone!(z),
                        child: const Text('Remove'),
                      ),
                  ],
                ),
              ),
            if (widget.onAddZone != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('airport-add-fare-zone'),
                  onPressed: widget.onAddZone,
                  icon: const Icon(Icons.add),
                  label: const Text('Add zone'),
                ),
              ),
          ],
        ),
        _section(
          context,
          children: [
            AirportSwitch(
              title: 'Round up the fare',
              subtitle:
                  'To the next whole amount, e.g. ${money(64.20)} becomes ${money(65)}',
              value: f.roundUp,
              onChanged: edit ? (v) => _set(f.copyWith(roundUp: v)) : null,
            ),
          ],
        ),
        AirportNote(
          'How a fare is worked out:\n'
          '1. Fixed zone fare if the other end is in a zone, else the distance band, else the normal rate\n'
          "2. + the service's airport base\n"
          '3. Raised to the minimum fare if lower\n'
          '4. + the airport charge (Charges tab)'
          '${f.roundUp ? '\n5. Rounded up to the next whole amount' : ''}',
        ),
        _gap,
        _trialCard(context),
      ],
    );
  }

  static String _km(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

  Widget _trialCard(BuildContext context) {
    final t = Theme.of(context);
    final s = widget.settings;
    final tr = _trial;
    final zone = widget.zones.where((z) => z.id == tr.zoneId).firstOrNull;
    final q = quoteAirportFare(
      fares: s.fares,
      side: tr.side,
      service: tr.service,
      km: tr.km,
      normal: tr.normal,
      perKm: tr.perKm,
      zoneFare: zone == null
          ? null
          : (
              name: zone.name,
              amount: tr.side == AirportSide.pick
                  ? zone.fromAmount
                  : zone.toAmount,
            ),
      charges: [
        if (s.chargeFor(tr.side).applied > 0)
          (
            name: s.chargeFor(tr.side).name,
            amount: s.chargeFor(tr.side).applied,
          ),
      ],
    );
    String money(double v) => formatMoney(v, widget.currency);
    return _section(
      context,
      key: const ValueKey('airport-fare-trial'),
      children: [
        Text('Try a fare', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        ListSearchFilter(
          count: widget.services.length,
          hint: 'Search services',
          fieldKey: const ValueKey('airport-trial-search'),
          builder: (context, q) => Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final sv in widget.services)
                if (q.isEmpty || searchSelectMatches(sv, q))
                  ChoiceChip(
                    label: Text(sv),
                    selected: tr.service == sv,
                    onSelected: (_) =>
                        setState(() => _trial = tr.copyWith(service: sv)),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('From the airport'),
              selected: tr.side == AirportSide.pick,
              onSelected: (_) =>
                  setState(() => _trial = tr.copyWith(side: AirportSide.pick)),
            ),
            ChoiceChip(
              label: const Text('To the airport'),
              selected: tr.side == AirportSide.drop,
              onSelected: (_) =>
                  setState(() => _trial = tr.copyWith(side: AirportSide.drop)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('By distance'),
              selected: tr.zoneId == null,
              onSelected: (_) =>
                  setState(() => _trial = tr.copyWith(byDistance: true)),
            ),
            for (final z in widget.zones)
              ChoiceChip(
                label: Text(z.name),
                selected: tr.zoneId == z.id,
                onSelected: (_) =>
                    setState(() => _trial = tr.copyWith(zoneId: z.id)),
              ),
          ],
        ),
        if (tr.zoneId == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AmountField(
                  value: tr.km,
                  label: 'Trip km',
                  width: 90,
                  onChanged: (v) => setState(() => _trial = tr.copyWith(km: v)),
                ),
                AmountField(
                  value: tr.normal,
                  label: 'Normal fare',
                  width: 110,
                  onChanged: (v) =>
                      setState(() => _trial = tr.copyWith(normal: v)),
                ),
                AmountField(
                  value: tr.perKm,
                  label: 'Normal per km',
                  width: 120,
                  onChanged: (v) =>
                      setState(() => _trial = tr.copyWith(perKm: v)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        for (final l in q.lines)
          Row(
            children: [
              Expanded(
                child: Text(
                  l.label,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(money(l.amount), style: t.textTheme.bodySmall),
            ],
          ),
        const Divider(),
        Row(
          key: const ValueKey('airport-fare-trial-total'),
          children: [
            const Expanded(child: Text('Rider pays')),
            Text(money(q.total), style: t.textTheme.titleMedium),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Charges
// ---------------------------------------------------------------------------

class AirportChargesTab extends StatelessWidget {
  const AirportChargesTab({
    super.key,
    required this.settings,
    this.onChanged,
    this.currency = 'MYR',
  });
  final AirportSettings settings;
  final ValueChanged<AirportSettings>? onChanged;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final on = onChanged;
    Widget charge(
      String key,
      String title,
      String subtitle,
      AirportCharge c,
      AirportSettings Function(AirportCharge) set,
    ) => _section(
      context,
      key: ValueKey('airport-charge-$key'),
      children: [
        AirportSwitch(
          title: title,
          subtitle: subtitle,
          value: c.on,
          onChanged: on == null
              ? null
              : (v) => on(
                  set(
                    AirportCharge(
                      on: v,
                      name: c.name,
                      amount: v && c.amount <= 0 ? 5 : c.amount,
                    ),
                  ),
                ),
        ),
        if (c.on)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: 220,
                child: NameField(
                  key: ValueKey('airport-charge-name-$key'),
                  value: c.name,
                  label: 'Name the rider sees',
                  onChanged: on == null
                      ? null
                      : (v) => on(
                          set(
                            AirportCharge(on: true, name: v, amount: c.amount),
                          ),
                        ),
                ),
              ),
              AmountField(
                key: ValueKey('airport-charge-amount-$key'),
                value: c.amount,
                label: 'Amount ($currency)',
                onChanged: on == null
                    ? null
                    : (v) => on(
                        set(AirportCharge(on: true, name: c.name, amount: v)),
                      ),
              ),
            ],
          ),
      ],
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const AirportNote(
          'Optional. A charge is added to the fare and shown to the rider before they confirm. Leave it off and nothing changes.',
        ),
        _gap,
        charge(
          'drop',
          'Drop-off at the airport',
          'Riders going to the airport',
          s.dropFee,
          (c) => s.copyWith(dropFee: c),
        ),
        charge(
          'pick',
          'Pickup at the airport',
          'Riders leaving from the airport',
          s.pickFee,
          (c) => s.copyWith(pickFee: c),
        ),
        const AirportNote(
          "The charge goes to the airport fee line on the receipt and isn't part of the driver's commission base.",
        ),
      ],
    );
  }
}

/// The vehicle services from lowest to highest, dragged into order. A driver
/// whose vehicle's service is higher may get orders for a lower one; a lower
/// one never sees a higher one's. Shared by every airport.
class ServiceOrderEditor extends StatelessWidget {
  const ServiceOrderEditor({
    super.key,
    required this.services,
    required this.order,
    this.onChanged,
  });
  final List<({String id, String name})> services;
  final ServiceOrder order;
  final ValueChanged<ServiceOrder>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    String name(String id) =>
        services.where((s) => s.id == id).firstOrNull?.name ?? id;
    final ids = order.ids;
    final on = onChanged;
    return Column(
      key: const ValueKey('airport-service-order'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Service order (lowest to highest)',
          style: t.textTheme.labelLarge,
        ),
        Text(
          'A driver whose vehicle is a higher service can get orders for the lower ones; a lower one never sees a '
          "higher one's. An order goes to its own service's line first, then to each higher line in this order. "
          'The same for every airport.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        if (ids.isEmpty)
          Text('No vehicle services yet.', style: t.textTheme.bodySmall),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => on?.call(order.moved(from, to)),
          children: [
            for (var i = 0; i < ids.length; i++)
              Card(
                key: ValueKey('airport-service-${ids[i]}'),
                margin: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  leading: on == null
                      ? CircleAvatar(radius: 13, child: Text('${i + 1}'))
                      : ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_indicator),
                        ),
                  title: Text('${i + 1}. ${name(ids[i])}'),
                  trailing: on == null
                      ? null
                      : Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Move ${name(ids[i])} lower',
                              onPressed: i == 0
                                  ? null
                                  : () => on(order.moved(i, i - 1)),
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Move ${name(ids[i])} higher',
                              onPressed: i == ids.length - 1
                                  ? null
                                  : () => on(order.moved(i, i + 1)),
                              icon: const Icon(Icons.arrow_downward, size: 18),
                            ),
                          ],
                        ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
