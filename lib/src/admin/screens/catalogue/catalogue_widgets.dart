import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import '../../../widgets/in_app_page.dart';

bool canEditPage(WidgetRef ref, String page) => ref.watch(pageAccessProvider(page)) == AccessLevel.edit;

/// Renders a stored image reference: a `data:` URL or an http(s) URL.
class StoredImage extends StatelessWidget {
  const StoredImage(this.uri, {super.key, this.size = 40, this.fallback = Icons.image_outlined, this.aspect = 1});
  final String uri;
  final double size;
  final double aspect;
  final IconData fallback;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget placeholder() => Icon(fallback, color: cs.onSurfaceVariant, size: size * 0.5);
    Widget child;
    if (uri.startsWith('data:')) {
      try {
        child = Image.memory(UriData.parse(uri).contentAsBytes(), fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder());
      } catch (_) {
        child = placeholder();
      }
    } else if (uri.startsWith('http')) {
      child = Image.network(uri, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder());
    } else {
      child = placeholder();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size * aspect,
        height: size,
        color: cs.surfaceContainerHighest,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// Image picker row that stores the image as a `data:` URL (how the Expo
/// screens store service / vehicle images).
class DataUrlImageField extends StatelessWidget {
  const DataUrlImageField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.aspect = 1,
    this.enabled = true,
  });
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final double aspect;
  final bool enabled;

  Future<void> _pick(BuildContext context) async {
    try {
      final f = await pickImageFile();
      if (f != null) onChanged(toDataUrl(f.bytes, f.name));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Row(children: [
            StoredImage(value, size: 72, aspect: aspect),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(
                  onPressed: enabled ? () => _pick(context) : null,
                  icon: const Icon(Icons.upload),
                  label: Text(value.isEmpty ? 'Upload' : 'Replace'),
                ),
                if (value.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: enabled ? () => onChanged('') : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
                if (value.startsWith('http'))
                  TextButton.icon(
                    onPressed: () => openInApp(context, value),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('View'),
                  ),
              ]),
            ),
          ]),
        ]),
      );
}

/// Body of an editor sheet: the form plus an error line and the save button
/// (disabled for read-only viewers).
class EditorBody extends StatelessWidget {
  const EditorBody({super.key, required this.children, required this.onSave, this.error, required this.saveLabel});
  final List<Widget> children;
  final VoidCallback? onSave;
  final String? error;
  final String saveLabel;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...children,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: onSave, icon: const Icon(Icons.save), label: Text(saveLabel)),
      ]);
}

/// Search box shown above catalogue lists.
class CatalogueSearch extends StatelessWidget {
  const CatalogueSearch({super.key, required this.onChanged, this.hint = 'Search', this.controller});
  final ValueChanged<String> onChanged;
  final String hint;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
        child: TextField(
          controller: controller,
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: hint, isDense: true),
          onChanged: onChanged,
        ),
      );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.hint});
  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, style: Theme.of(context).textTheme.titleSmall),
          if (hint != null) Text(hint!, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

/// Multi-select chips with an "All" token (doc types, partner types).
class AllTokenChips extends StatelessWidget {
  const AllTokenChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.emptyText,
  });

  /// id → label
  final Map<String, String> options;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final all = selected.contains(allToken);
    return Wrap(spacing: 8, runSpacing: 4, children: [
      FilterChip(
        label: const Text('All'),
        selected: all,
        onSelected: (_) => onChanged(toggleWithAll(selected, allToken)),
      ),
      if (options.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(emptyText)),
      for (final o in options.entries)
        FilterChip(
          label: Text(o.value),
          selected: !all && selected.contains(o.key),
          onSelected: all ? null : (_) => onChanged(toggleWithAll(selected, o.key)),
        ),
    ]);
  }
}

/// Up/down reorder controls.
class ReorderButtons extends StatelessWidget {
  const ReorderButtons({super.key, required this.onUp, required this.onDown});
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Move up',
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: onUp,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Move down',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: onDown,
        ),
      ]);
}

/// Opens an editor in the admin side/bottom sheet.
Future<T?> openEditor<T>(BuildContext context, String title, Widget editor) =>
    showAdminSheet<T>(context, title: title, builder: (_) => editor);

/// Small pill.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: cs.onSecondaryContainer), const SizedBox(width: 3)],
        Text(text, style: TextStyle(fontSize: 11, color: cs.onSecondaryContainer, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
