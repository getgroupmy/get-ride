// "Assistance required": the sheet the Options switch opens (what help,
// grouped, with a choice where the item asks for one and a note for the
// driver), the help as the driver and admins see it, and the line naming
// what the options add to the fare. In the app's light or dark theme.
import 'package:flutter/material.dart';

import '../../core/ride_assistance.dart';
import '../../core/ride_option_charges.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/media_image.dart' show MediaIcon;
import '../../widgets/search_select.dart' show ListSearchFilter;

/// The "What help do you need?" sheet: the help when Done is pressed, null
/// when it was cancelled (Cancel, a tap on the scrim or a swipe down),
/// which keeps whatever was saved before.
Future<RideAssistance?> showRideAssistanceSheet(
  BuildContext context, {
  RideAssistance? initial,
  AssistanceCatalogue catalogue = const AssistanceCatalogue(),
}) => showAppSheet<RideAssistance>(id: 'ride.assistance',
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  // A strip of the screen stays above it, to tap away.
  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
  builder: (_) => RideAssistanceSheet(initial: initial, catalogue: catalogue),
);

class RideAssistanceSheet extends StatefulWidget {
  const RideAssistanceSheet({super.key, this.initial, this.catalogue = const AssistanceCatalogue()});
  final RideAssistance? initial;
  final AssistanceCatalogue catalogue;

  @override
  State<RideAssistanceSheet> createState() => _RideAssistanceSheetState();
}

class _RideAssistanceSheetState extends State<RideAssistanceSheet> {
  /// What is picked, by item id, in the order it was picked.
  late final Map<String, AssistancePick> _picked = {
    for (final p in widget.initial?.items ?? const <AssistancePick>[]) p.id: p,
  };
  late final _note = TextEditingController(text: widget.initial?.note ?? '');

  AssistanceCatalogue get _c => widget.catalogue;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// The picks in the catalogue's order, then any saved one the admin no
  /// longer offers.
  List<AssistancePick> get _picks => [
    for (final i in _c.items)
      if (_picked.containsKey(i.id)) _picked[i.id]!,
    for (final p in _picked.values)
      if (_c.byId(p.id) == null) p,
  ];

  void _toggle(AssistanceItem item, bool on) => setState(() {
    if (on) {
      _picked[item.id] = AssistancePick.of(item, choice: item.choices.length == 1 ? item.choices.first : null);
    } else {
      _picked.remove(item.id);
    }
  });

  void _choose(AssistanceItem item, String choice) => setState(() {
    // The admin's current name and emoji go with it.
    _picked[item.id] = AssistancePick.of(item, choice: choice);
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final picks = _picks;
    final missing = assistanceMissingText(picks, _c);
    final done = assistanceComplete(picks, _c);
    final offered = _c.visible;
    final gone = [for (final p in picks) if (_c.byId(p.id) == null) p];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          key: const ValueKey('ride-assistance'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('What help do you need?', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Pick all that apply. Drivers see them before they accept.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListSearchFilter(
                      count: offered.length,
                      hint: 'Search help',
                      fieldKey: const ValueKey('assist-search'),
                      builder: (context, q) {
                        final l = q.toLowerCase();
                        final shown = [
                          for (final i in offered)
                            if (l.isEmpty ||
                                i.name.toLowerCase().contains(l) ||
                                i.description.toLowerCase().contains(l) ||
                                i.group.toLowerCase().contains(l))
                              i,
                        ];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final e in AssistanceCatalogue.byGroup(shown).entries) ...[
                              Padding(
                                padding: const EdgeInsets.only(top: 12, bottom: 4),
                                child: Text(
                                  e.key,
                                  key: ValueKey('assist-group-${e.key}'),
                                  style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                                ),
                              ),
                              for (final item in e.value) _item(context, item),
                            ],
                          ],
                        );
                      },
                    ),
                    if (gone.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 4),
                        child: Text(
                          'Picked before',
                          style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      for (final p in gone)
                        _row(
                          context,
                          key: 'assist-item-${p.id}',
                          emoji: p.emoji,
                          name: p.label,
                          description: null,
                          selected: true,
                          onChanged: (_) => setState(() => _picked.remove(p.id)),
                        ),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('assist-note'),
                      controller: _note,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: assistanceNoteMax,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Anything else the driver should know',
                        helperText: 'Only the driver who takes your ride sees this.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(children: [
                Expanded(
                  child: Text(
                    missing ?? '',
                    key: const ValueKey('assist-missing'),
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const ValueKey('assist-cancel'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('assist-done'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: done
                      ? () => Navigator.pop(
                          context,
                          RideAssistance(
                            items: List.of(picks),
                            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                          ),
                        )
                      : null,
                  child: const Text('Done'),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, AssistanceItem item) {
    final pick = _picked[item.id];
    final on = pick != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(
          context,
          key: 'assist-item-${item.id}',
          emoji: item.emoji,
          icon: item.icon,
          name: item.name,
          description: item.description.isEmpty ? null : item.description,
          selected: on,
          onChanged: (v) => _toggle(item, v),
        ),
        if (on && item.choices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(48, 0, 0, 8),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (var i = 0; i < item.choices.length; i++)
                ChoiceChip(
                  key: ValueKey('assist-choice-${item.id}-$i'),
                  label: Text(item.choices[i]),
                  selected: pick.choice == item.choices[i],
                  onSelected: (_) => _choose(item, item.choices[i]),
                ),
            ]),
          ),
      ],
    );
  }

  Widget _row(
    BuildContext context, {
    required String key,
    required String emoji,
    String icon = '',
    required String name,
    required String? description,
    required bool selected,
    required ValueChanged<bool> onChanged,
  }) {
    final t = Theme.of(context);
    return InkWell(
      key: ValueKey(key),
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged(!selected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
            width: 40,
            // The admin's icon when it has one, else the emoji.
            child: icon.isEmpty
                ? Text(emoji, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24))
                : Center(child: MediaIcon(icon, fallback: Icons.accessibility_new, size: 26)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: t.textTheme.bodyLarge),
              if (description != null)
                Text(description, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          Checkbox(value: selected, onChanged: (v) => onChanged(v ?? false)),
        ]),
      ),
    );
  }
}

/// The help the rider asked for, for the driver (request sheet, trip
/// screen) and admins: "Rider needs assistance", each item with its emoji
/// and choice, then the rider's note. [locked]: the request is still open,
/// when the note waits for the driver who takes it (migration 0248).
class RideAssistanceView extends StatelessWidget {
  const RideAssistanceView({super.key, required this.assistance, this.locked = false, this.title});
  final RideAssistance assistance;
  final bool locked;

  /// The option's name as the ride was booked, when the admin renamed it;
  /// else "Rider needs assistance".
  final String? title;

  @override
  Widget build(BuildContext context) {
    if (assistance.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final note = assistance.note;
    return Column(
      key: const ValueKey('ride-assistance-view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Icon(Icons.accessibility_new, size: 18, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title ?? 'Rider needs assistance',
              key: const ValueKey('assist-flag'),
              style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        for (var i = 0; i < assistance.items.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 24,
                child: Text(assistance.items[i].emoji, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(assistance.items[i].name, key: ValueKey('assist-view-item-$i'), style: t.textTheme.bodyMedium),
                  if (assistance.items[i].choice != null)
                    Text(
                      assistance.items[i].choice!,
                      key: ValueKey('assist-view-choice-$i'),
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ]),
              ),
            ]),
          ),
        if (!locked && note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '“$note”',
              key: const ValueKey('assist-view-note'),
              style: t.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              "Any note from the rider shows once you accept.",
              key: const ValueKey('assist-note-after-accept'),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
      ],
    );
  }
}

/// What the rider's options add to the fare, for the driver and admins:
/// "Includes Pet charge RM10 · Assistance charge RM5". Nothing for none.
class OptionChargesLine extends StatelessWidget {
  const OptionChargesLine({super.key, required this.lines, required this.money});
  final List<OptionChargeLine> lines;
  final String Function(double amount) money;

  @override
  Widget build(BuildContext context) {
    final text = optionChargesText(lines, money);
    if (text == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Text(
      'Fare includes $text',
      key: const ValueKey('option-charges-line'),
      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
    );
  }
}
