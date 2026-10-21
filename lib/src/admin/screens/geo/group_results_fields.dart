import 'package:flutter/material.dart';

import '../../../widgets/common.dart' show mutedTextColor;
import 'geo_logic.dart';

/// "Group search results inside the boundary" and "Also group results
/// named", on Edit Airport and Edit Place: the rider's search shows the
/// addresses, roads and shops inside the boundary, and results named with
/// one of the words, as this one result (`values.groupResults`,
/// `values.groupWords`). The words are dimmed while the switch is off; the
/// whole section is when [disabledHint] says why it can't be used yet.
class GroupResultsFields extends StatefulWidget {
  const GroupResultsFields({
    super.key,
    required this.value,
    required this.words,
    required this.onChanged,
    this.disabledHint,
  });

  final bool value;
  final List<String> words;

  /// The switch and the words as changed.
  final void Function(bool value, List<String> words) onChanged;

  /// Why it can't be switched on ("Draw a boundary first"); null when it can.
  final String? disabledHint;

  @override
  State<GroupResultsFields> createState() => _GroupResultsFieldsState();
}

class _GroupResultsFieldsState extends State<GroupResultsFields> {
  final _word = TextEditingController();

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  void _add() {
    final words = addGroupWord(widget.words, _word.text);
    _word.clear();
    if (!identical(words, widget.words)) widget.onChanged(widget.value, words);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final enabled = widget.disabledHint == null;
    final wordsOn = enabled && widget.value;
    return Column(
      key: const ValueKey('group-results'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('group-results-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Group search results inside the boundary'),
          subtitle: Text(widget.disabledHint ?? 'Addresses, roads and shops inside show as this one result.'),
          value: enabled && widget.value,
          onChanged: enabled ? (v) => widget.onChanged(v, widget.words) : null,
        ),
        Opacity(
          opacity: wordsOn ? 1 : 0.45,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Also group results named', style: t.textTheme.titleSmall),
              if (widget.words.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final w in widget.words)
                      InputChip(
                        key: ValueKey('group-word-$w'),
                        label: Text(w),
                        isEnabled: wordsOn,
                        deleteButtonTooltipMessage: 'Remove $w',
                        onDeleted: wordsOn
                            ? () => widget.onChanged(widget.value, [for (final x in widget.words) if (x != w) x])
                            : null,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('group-words-field'),
                      controller: _word,
                      enabled: wordsOn,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(hintText: 'Add a word, e.g. klia2'),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    key: const ValueKey('group-words-add'),
                    tooltip: 'Add word',
                    onPressed: wordsOn ? _add : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'For results Google gives without a position.',
                key: const ValueKey('group-words-hint'),
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
