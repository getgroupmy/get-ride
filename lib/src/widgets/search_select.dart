// A dropdown that can be searched once its list is long: up to
// [kSearchSelectFrom] - 1 choices it is the usual dropdown; from there, a tap
// opens a list with a search box at the top (type a few letters of "Selangor"
// instead of scrolling past the other states). Takes the same arguments as
// DropdownButtonFormField, so it drops in where one was.
import 'package:flutter/material.dart';

import 'page_style_host.dart';

/// How many choices make a dropdown searchable.
const kSearchSelectFrom = 8;

/// The words a choice is found by: its Text, else its value.
String searchSelectLabel<T>(DropdownMenuItem<T> item) {
  // The words in a choice, looking through the usual wrappers (a row of an
  // icon and its name, padding, a flexible).
  String? textOf(Widget w) => switch (w) {
        Text(:final data?) => data,
        Text(:final textSpan?) => textSpan.toPlainText(),
        RichText(:final text) => text.toPlainText(),
        Flex(:final children) =>
          children.map(textOf).whereType<String>().where((t) => t.isNotEmpty).join(' ').ifEmpty,
        Padding(:final child?) || Align(:final child?) || SizedBox(:final child?) || Flexible(:final child) ||
        DefaultTextStyle(:final child) || Tooltip(:final child?) =>
          textOf(child),
        _ => null,
      };
  return textOf(item.child) ?? '${item.value ?? ''}';
}

extension on String {
  String? get ifEmpty => isEmpty ? null : this;
}

/// Whether [label] matches what was typed: every word, anywhere, any case.
bool searchSelectMatches(String label, String query) {
  final l = label.toLowerCase();
  return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(l.contains);
}

class SearchableDropdownFormField<T> extends StatelessWidget {
  const SearchableDropdownFormField({
    super.key,
    required this.items,
    this.initialValue,
    this.onChanged,
    this.decoration,
    this.isExpanded = false,
    this.hint,
    this.validator,
    this.searchFrom = kSearchSelectFrom,
  });

  final List<DropdownMenuItem<T>>? items;
  final T? initialValue;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;
  final bool isExpanded;
  final Widget? hint;
  final FormFieldValidator<T>? validator;

  /// From how many choices the list is searchable.
  final int searchFrom;

  @override
  Widget build(BuildContext context) {
    final list = items ?? const [];
    if (list.length < searchFrom) {
      return DropdownButtonFormField<T>(
        items: items,
        initialValue: initialValue,
        onChanged: onChanged,
        decoration: decoration ?? const InputDecoration(),
        isExpanded: isExpanded,
        hint: hint,
        validator: validator,
      );
    }
    return _SearchField<T>(
      items: list,
      initialValue: initialValue,
      onChanged: onChanged,
      decoration: decoration ?? const InputDecoration(),
      hint: hint,
      validator: validator,
    );
  }
}

class _SearchField<T> extends FormField<T> {
  _SearchField({
    required this.items,
    required super.initialValue,
    required this.onChanged,
    required this.decoration,
    Widget? hint,
    super.validator,
  }) : super(
          builder: (field) {
            final state = field as _SearchFieldState<T>;
            final selected = items.where((i) => i.value == field.value).firstOrNull;
            final enabled = onChanged != null;
            final shown = decoration.applyDefaults(Theme.of(field.context).inputDecorationTheme).copyWith(
                  errorText: field.errorText,
                  enabled: enabled,
                  suffixIcon: decoration.suffixIcon ?? const Icon(Icons.search),
                );
            return Semantics(
              button: true,
              child: InkWell(
                onTap: enabled ? state.pick : null,
                child: InputDecorator(
                  decoration: shown,
                  isEmpty: selected == null && hint == null,
                  child: selected != null
                      ? DefaultTextStyle.merge(maxLines: 1, overflow: TextOverflow.ellipsis, child: selected.child)
                      : (hint ?? const SizedBox(height: 20)),
                ),
              ),
            );
          },
        );

  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;

  @override
  FormFieldState<T> createState() => _SearchFieldState<T>();
}

class _SearchFieldState<T> extends FormFieldState<T> {
  @override
  _SearchField<T> get widget => super.widget as _SearchField<T>;

  @override
  void didUpdateWidget(covariant _SearchField<T> old) {
    super.didUpdateWidget(old);
    // The owner picked a new value itself (a reset, a parent changed): follow it.
    if (old.initialValue != widget.initialValue) setValue(widget.initialValue);
  }

  Future<void> pick() async {
    final chosen = await showAppDialog<_Chosen<T>>(
      id: 'common.search-select',
      context: context,
      builder: (_) => _SearchDialog<T>(items: widget.items, selected: value, title: widget.decoration.labelText),
    );
    if (chosen == null || !mounted) return;
    didChange(chosen.value);
    widget.onChanged?.call(chosen.value);
  }
}

/// A pick, so a null value can be chosen too.
class _Chosen<T> {
  const _Chosen(this.value);
  final T? value;
}

class _SearchDialog<T> extends StatefulWidget {
  const _SearchDialog({required this.items, required this.selected, this.title, this.labels});
  final List<DropdownMenuItem<T>> items;

  /// What each item is found by, where its widget doesn't say.
  final List<String>? labels;
  final T? selected;
  final String? title;

  @override
  State<_SearchDialog<T>> createState() => _SearchDialogState<T>();
}

class _SearchDialogState<T> extends State<_SearchDialog<T>> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = _query.text.trim();
    String labelOf(int n) => widget.labels?[n] ?? searchSelectLabel(widget.items[n]);
    final shown = [
      for (var n = 0; n < widget.items.length; n++)
        if (q.isEmpty || searchSelectMatches(labelOf(n), q)) widget.items[n],
    ];
    final searchable = widget.items.length >= kSearchSelectFrom;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: size.height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if ((widget.title ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Text(widget.title!, style: t.textTheme.titleMedium),
              ),
            if (searchable) Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                key: const ValueKey('search-select-field'),
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: q.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(_query.clear),
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
                // Enter takes the only match.
                onSubmitted: (typed) {
                  final t = typed.trim();
                  final hits = [
                    for (var n = 0; n < widget.items.length; n++)
                      if (widget.items[n].enabled && (t.isEmpty || searchSelectMatches(labelOf(n), t))) widget.items[n],
                  ];
                  if (hits.length == 1) Navigator.pop(context, _Chosen<T>(hits.single.value));
                },
              ),
            ),
            if (searchable) Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                q.isEmpty ? '${widget.items.length} choices' : '${shown.length} of ${widget.items.length}',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
            Flexible(
              child: shown.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Nothing matches "$q".', textAlign: TextAlign.center),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      itemBuilder: (context, n) {
                        final i = shown[n];
                        final on = i.value == widget.selected;
                        return ListTile(
                          key: ValueKey('search-select-item-${widget.labels == null ? searchSelectLabel(i) : '${i.value}'}'),
                          enabled: i.enabled,
                          selected: on,
                          title: DefaultTextStyle.merge(
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            child: i.child,
                          ),
                          trailing: on ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(context, _Chosen<T>(i.value)),
                        );
                      },
                    ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One choice in [showSearchPicker].
typedef SearchChoice<T> = ({T value, String label, String? subtitle, Widget? leading});

/// Asks for one of [choices] in a dialog with a search box (shown from
/// [kSearchSelectFrom] choices). Null when cancelled.
Future<T?> showSearchPicker<T>(
  BuildContext context, {
  required String title,
  required List<SearchChoice<T>> choices,
  T? selected,
}) async {
  final chosen = await showAppDialog<_Chosen<T>>(
    id: 'common.search-picker',
    context: context,
    builder: (_) => _SearchDialog<T>(
      title: title,
      selected: selected,
      items: [
        for (final c in choices)
          DropdownMenuItem<T>(
            value: c.value,
            child: _ChoiceRow(label: c.label, subtitle: c.subtitle, leading: c.leading),
          ),
      ],
      labels: [for (final c in choices) '${c.label} ${c.subtitle ?? ''}'],
    ),
  );
  return chosen?.value;
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, this.subtitle, this.leading});
  final String label;
  final String? subtitle;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (leading != null) ...[leading!, const SizedBox(width: 12)],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            if ((subtitle ?? '').isNotEmpty)
              Text(
                subtitle!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// A search box above a long list of choices (chips, ticks, records): from
/// [from] items it shows, and [builder] gets what was typed to filter by.
/// Short lists get no box, and [builder] gets ''.
class ListSearchFilter extends StatefulWidget {
  const ListSearchFilter({
    super.key,
    required this.count,
    required this.builder,
    this.hint = 'Search',
    this.from = kSearchSelectFrom,
    this.fieldKey = const ValueKey('list-search'),
  });

  final int count;
  final Widget Function(BuildContext context, String query) builder;
  final String hint;
  final int from;
  final Key fieldKey;

  @override
  State<ListSearchFilter> createState() => _ListSearchFilterState();
}

class _ListSearchFilterState extends State<ListSearchFilter> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count < widget.from) return widget.builder(context, '');
    final q = _query.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextField(
            key: widget.fieldKey,
            controller: _query,
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: () => setState(_query.clear)),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        widget.builder(context, q),
      ],
    );
  }
}
