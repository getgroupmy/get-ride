import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import 'commerce_data.dart';
import 'commerce_logic.dart';
import 'countries.dart';
import '../../../widgets/net_image.dart';

/// Opens [child] as a full-screen dialog on phones and a centred, capped
/// dialog on wide screens.
Future<T?> showFormDialog<T>(BuildContext context, Widget Function(BuildContext) builder) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  return showDialog<T>(
    context: context,
    builder: (ctx) => wide
        ? Dialog(
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 820), child: builder(ctx)),
          )
        : Dialog.fullscreen(child: builder(ctx)),
  );
}

/// Scaffold body for a form dialog: title bar with close + save. A save that
/// returns a Future shows a spinner on the button until it completes.
class FormDialogScaffold extends StatelessWidget {
  const FormDialogScaffold({
    super.key,
    required this.title,
    required this.children,
    required this.onSave,
    this.saveLabel = 'Save',
    this.error,
  });

  final String title;
  final List<Widget> children;
  final BusyAction? onSave;
  final String saveLabel;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          title: Text(title),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: BusyButton.filled(onPressed: onSave, child: Text(saveLabel)),

            ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
          if (error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          ...children,
        ]),
      );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.icon, this.trailing});
  final String text;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 6)],
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleSmall)),
          ?trailing,
        ]),
      );
}

/// Search field above a list.
class ListSearch extends StatelessWidget {
  const ListSearch({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: hint, isDense: true),
          onChanged: onChanged,
        ),
      );
}

/// Renders a stored image reference: a `data:` URL (how the Expo app stores
/// EV images) or a regular URL.
class StoredImage extends StatelessWidget {
  const StoredImage(this.uri, {super.key, this.width, this.height, this.fit = BoxFit.cover, this.placeholder});
  final String uri;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData? placeholder;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Icon(placeholder ?? Icons.electric_car, color: Theme.of(context).colorScheme.onPrimaryContainer),
    );
    if (uri.isEmpty) return fallback;
    if (uri.startsWith('data:')) {
      final comma = uri.indexOf(',');
      try {
        final bytes = base64Decode(uri.substring(comma + 1));
        return Image.memory(bytes, width: width, height: height, fit: fit, errorBuilder: (_, _, _) => fallback);
      } catch (_) {
        return fallback;
      }
    }
    return Image.network(uri, width: width, height: height, fit: fit, frameBuilder: boneUntilPainted(width: width, height: height), errorBuilder: (_, _, _) => fallback);
  }
}

/// Field that opens a searchable country list (free text allowed for names
/// the list lacks).
class CountryField extends StatelessWidget {
  const CountryField({super.key, required this.value, required this.onChanged, this.enabled = true});
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: !enabled
            ? null
            : () async {
                final picked = await showDialog<String>(context: context, builder: (_) => _CountryPicker(selected: value));
                if (picked != null) onChanged(picked);
              },
        child: InputDecorator(
          decoration: const InputDecoration(labelText: 'Country *', prefixIcon: Icon(Icons.public), suffixIcon: Icon(Icons.arrow_drop_down)),
          child: Text(value.isEmpty ? 'Select country' : value),
        ),
      );
}

class _CountryPicker extends StatefulWidget {
  const _CountryPicker({required this.selected});
  final String selected;

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final names = worldCountryCurrencies.keys.toList()..sort();
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty ? names : names.where((n) => n.toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: const Text('Select country'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 480,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search country', isDense: true),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              for (final n in list)
                ListTile(
                  dense: true,
                  title: Text(n),
                  trailing: n == widget.selected ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, n),
                ),
              if (list.isEmpty && _q.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text('Use "${_q.trim()}"'),
                  onTap: () => Navigator.pop(context, _q.trim()),
                ),
            ]),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

/// Picker for a configured payment gateway account ("None" allowed).
class GatewayPickerField extends ConsumerWidget {
  const GatewayPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Payment Gateway Account',
    this.helperText,
  });

  final SelectedGateway? value;
  final ValueChanged<SelectedGateway?> onChanged;
  final String label;
  final String? helperText;

  @override
  Widget build(BuildContext context, WidgetRef ref) => InkWell(
        onTap: () async {
          final accounts = await ref.read(gatewayAccountsProvider.future).catchError((Object e) {
            if (context.mounted) showError(context, e);
            return <SelectedGateway>[];
          });
          if (!context.mounted) return;
          final result = await showDialog<({SelectedGateway? g})>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('Select gateway account'),
              children: [
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, (g: null)),
                  child: ListTile(
                    leading: const Icon(Icons.block),
                    title: const Text('None (skip)'),
                    trailing: value == null ? const Icon(Icons.check) : null,
                  ),
                ),
                if (accounts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No active gateway accounts. Add one in Payment Gateways first.'),
                  ),
                for (final a in accounts)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, (g: a)),
                    child: ListTile(
                      leading: const Icon(Icons.credit_card),
                      title: Text(a.providerName),
                      subtitle: Text('${a.accountName} · ${a.mode}'),
                      trailing: value?.id == a.id ? const Icon(Icons.check) : null,
                    ),
                  ),
              ],
            ),
          );
          if (result != null) onChanged(result.g);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            helperText: helperText,
            helperMaxLines: 2,
            prefixIcon: const Icon(Icons.credit_card),
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          child: Text(value?.label ?? 'None (skip)', overflow: TextOverflow.ellipsis),
        ),
      );
}

/// Segmented choice for a short list of string options.
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({super.key, required this.options, required this.value, required this.onChanged});
  final List<String> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final o in options) ChoiceChip(label: Text(o), selected: value == o, onSelected: (_) => onChanged(o)),
      ]);
}
