// Sign-in checks (migrations 0283, 0320): who compares the selfie with the
// ID photo and who reads the MyKad or passport, each an order the admin
// changes with the arrows, every entry with its own switch:
//   face match   AWS, then the office NAS, then the in-browser check;
//   ID reading   the phone, then the office NAS, then Google Vision;
// and the match below which a check "Needs a closer look". In Dispatch →
// Accounts next to "Ask for a new ID", and in Settings → Office NAS → ID and
// face. Each change is saved as it is made. A line under each says when a
// key is missing in Admin → API Keys, or the NAS isn't connected, so nobody
// wonders why a face reads "Not checked". The face match is a score only:
// nothing here approves anyone.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/signin_checks.dart';
import '../../../data/identity_repository.dart';
import '../../../widgets/common.dart';

class IdentityProviderFields extends ConsumerStatefulWidget {
  const IdentityProviderFields({super.key, this.enabled = true});

  final bool enabled;

  @override
  ConsumerState<IdentityProviderFields> createState() => _IdentityProviderFieldsState();
}

class _IdentityProviderFieldsState extends ConsumerState<IdentityProviderFields> {
  IdentityConfig? _saved;
  bool _busy = false;

  Future<void> _set({List<OrderSlot>? face, List<OrderSlot>? read, int? low}) async {
    setState(() => _busy = true);
    try {
      final c = await ref
          .read(identityRepositoryProvider)
          .setOrder(faceOrder: face, idReaders: read, faceLowScore: low);
      if (!mounted) return;
      setState(() => _saved = c);
      ref.invalidate(identityConfigProvider);
      showInfo(context, 'Saved');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final warn = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error);
    final c = _saved ?? ref.watch(identityConfigProvider).value;
    if (c == null) return const SizedBox.shrink();
    final on = widget.enabled && !_busy;
    Widget note(String? s, String key) =>
        s == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 4), child: Text(s, key: ValueKey(key), style: warn));
    final nasMissing = c.nasReader == false &&
        (orderHas(c.idReaders, 'nas'))
        ? 'No NAS connected yet: connect it in Admin, Settings, Document reading. Until then it is skipped.'
        : null;
    return Column(
      key: const ValueKey('identity-providers'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Checking their photos', style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text('Face match, in order', style: t.textTheme.labelLarge),
        OrderEditor(
          keyPrefix: 'face-order',
          order: c.faceOrder,
          names: faceOrderNames,
          enabled: on,
          onChanged: (o) => _set(face: o),
        ),
        Text(
          'Faces are compared by: ${orderText(c.faceOrder, faceOrderWords)}. Each is asked when the one before it '
          "can't answer. It is a score that helps you decide: it never approves or rejects anyone.",
          key: const ValueKey('face-order-summary'),
          style: muted,
        ),
        note(c.faceNote, 'face-provider-note'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Needs a closer look below ${c.faceLowScore}% match',
                key: const ValueKey('face-low-score'),
                style: t.textTheme.bodyMedium,
              ),
            ),
            IconButton(
              key: const ValueKey('face-low-down'),
              tooltip: 'Lower',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: on && c.faceLowScore > 30 ? () => _set(low: (c.faceLowScore - 5).clamp(30, 95)) : null,
            ),
            IconButton(
              key: const ValueKey('face-low-up'),
              tooltip: 'Higher',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: on && c.faceLowScore < 95 ? () => _set(low: (c.faceLowScore + 5).clamp(30, 95)) : null,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('ID card reading, in order', style: t.textTheme.labelLarge),
        OrderEditor(
          keyPrefix: 'id-reader',
          order: c.idReaders,
          names: idReaderNames,
          enabled: on,
          onChanged: (o) => _set(read: o),
        ),
        Text(
          'Reads the name, IC or passport number, birth date and expiry off the card, to check against the '
          'profile: ${orderText(c.idReaders, idReaderWords)}. The NAS and Google Vision also read for the web and '
          'desktop, where the phone can\'t. Google Vision: first 1,000 reads a month free.',
          key: const ValueKey('id-read-help'),
          style: muted,
        ),
        note(c.visionNote, 'id-read-note'),
        note(nasMissing, 'id-read-nas-note'),
      ],
    );
  }
}

/// An order of readers or checkers: the arrows move one, the switch turns it
/// on or off. Keys: `<prefix>-<id>`, `-up-`, `-down-`, `-switch-`.
class OrderEditor extends StatelessWidget {
  const OrderEditor({
    super.key,
    required this.keyPrefix,
    required this.order,
    required this.names,
    required this.enabled,
    required this.onChanged,
  });

  final String keyPrefix;
  final List<OrderSlot> order;
  final Map<String, (String, String)> names;
  final bool enabled;
  final ValueChanged<List<OrderSlot>> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    var n = 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, x) in order.indexed)
          ListTile(
            key: ValueKey('$keyPrefix-${x.id}'),
            contentPadding: EdgeInsets.zero,
            enabled: x.on,
            leading: SizedBox(
              width: 24,
              child: Text(
                x.on ? '${++n}' : '–',
                textAlign: TextAlign.center,
                style: t.textTheme.titleSmall,
              ),
            ),
            title: Text(names[x.id]?.$1 ?? x.id),
            subtitle: Text(names[x.id]?.$2 ?? ''),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('$keyPrefix-up-${x.id}'),
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: enabled && i > 0 ? () => onChanged(movedSlot(order, x.id, -1)) : null,
                ),
                IconButton(
                  key: ValueKey('$keyPrefix-down-${x.id}'),
                  tooltip: 'Move down',
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: enabled && i < order.length - 1 ? () => onChanged(movedSlot(order, x.id, 1)) : null,
                ),
                Switch(
                  key: ValueKey('$keyPrefix-switch-${x.id}'),
                  value: x.on,
                  onChanged: enabled ? (v) => onChanged(toggledSlot(order, x.id, v)) : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
