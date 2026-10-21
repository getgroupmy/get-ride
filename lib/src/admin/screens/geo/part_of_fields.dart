import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart' show mutedTextColor;
import '../../../widgets/search_select.dart' show searchSelectMatches;
import 'geo_data.dart';
import 'geo_logic.dart';

/// "Part of (optional)" and its "Order", on Edit Place and Edit Airport:
/// places and airports with the same Part of name (KLIA Terminal 1 and 2,
/// both part of KLIA) open together in the rider's door sheet, a wheel of
/// the places beside the doors. The names already used are suggested as
/// the admin types; the line under the fields says what the rider will see.
class PartOfFields extends ConsumerStatefulWidget {
  const PartOfFields({super.key, required this.partOf, required this.order, this.selfId});

  final TextEditingController partOf, order;

  /// The place or airport being edited (null when adding one).
  final String? selfId;

  @override
  ConsumerState<PartOfFields> createState() => _PartOfFieldsState();
}

class _PartOfFieldsState extends ConsumerState<PartOfFields> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final members = partOfMembers([
      for (final e in ref.watch(multiGatePlacesProvider).value ?? const <GeoEntry>[]) (id: e.id, values: e.values),
      for (final e in ref.watch(airportsProvider).value ?? const <GeoEntry>[]) (id: e.id, values: e.values),
    ]);
    final names = partOfNames([for (final m in members) if (m.id != widget.selfId) m]);
    return Column(
      key: const ValueKey('part-of'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: RawAutocomplete<String>(
                textEditingController: widget.partOf,
                focusNode: _focus,
                optionsBuilder: (v) {
                  final q = v.text.trim();
                  return [
                    for (final n in names)
                      if (n.toLowerCase() != q.toLowerCase() && (q.isEmpty || searchSelectMatches(n, q))) n,
                  ];
                },
                fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                  key: const ValueKey('part-of-field'),
                  controller: controller,
                  focusNode: focusNode,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Part of (optional)', hintText: 'e.g. KLIA'),
                ),
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    color: t.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240, maxWidth: 360),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        children: [
                          for (final o in options)
                            ListTile(
                              key: ValueKey('part-of-option-$o'),
                              dense: true,
                              leading: const Icon(Icons.link, size: 18),
                              title: Text(o),
                              onTap: () => onSelected(o),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 96,
              child: TextField(
                key: const ValueKey('part-order-field'),
                controller: widget.order,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Order', hintText: '1'),
              ),
            ),
          ],
        ),
        ListenableBuilder(
          listenable: widget.partOf,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  partOfHint(widget.partOf.text, members, selfId: widget.selfId),
                  key: const ValueKey('part-of-hint'),
                  style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                ),
                if (widget.partOf.text.trim().isNotEmpty)
                  TextButton.icon(
                    key: const ValueKey('part-of-clear'),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () {
                      widget.partOf.clear();
                      widget.order.text = '1';
                    },
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('Not part of another place'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
