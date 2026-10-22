// Courier (migration 0268) on the trip screens: the parcel's size and who
// pays as the courier and admins read them, the confirmation code the
// sender passes on, and the dialog where the courier types it in at
// drop-off (the server checks it, courier_code_check).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/courier.dart';
import '../../data/freight_repository.dart';
import '../../data/models.dart';
import '../../widgets/common.dart' show CodeField, errorText;

/// A courier request's parcel: its size and kilos, and, when the recipient
/// pays, the cash the courier collects at drop-off.
class CourierParcelLines extends ConsumerWidget {
  const CourierParcelLines({super.key, required this.request});
  final RideRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final size = ParcelSize.byId(r.parcelSize);
    if (size == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final config = ref.watch(courierConfigProvider).value ?? const CourierConfig();
    return Column(
      key: ValueKey('courier-parcel-${r.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Icon(Icons.inventory_2_outlined, size: 18, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Parcel ${parcelSizeText(size, config)}',
              key: const ValueKey('courier-parcel-size'),
              style: t.textTheme.bodySmall,
            ),
          ),
        ]),
        if (r.recipientPays)
          Container(
            key: const ValueKey('courier-collect'),
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: t.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.payments_outlined, size: 18, color: t.colorScheme.onTertiaryContainer),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  collectFromRecipientText(r.fareText(r.effectiveFare)),
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
          ),
      ],
    );
  }
}

/// The confirmation code for the sender to pass on, with how it reaches the
/// recipient; nothing while it isn't theirs to see.
class CourierCodeCard extends ConsumerWidget {
  const CourierCodeCard({super.key, required this.request});
  final RideRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    if (!r.isCourier) return const SizedBox.shrink();
    final t = Theme.of(context);
    final config = ref.watch(courierConfigProvider).value ?? const CourierConfig();
    if (r.deliveryCodeOkAt != null) {
      return Row(key: const ValueKey('courier-code-done'), children: [
        Icon(Icons.verified_outlined, color: t.colorScheme.primary),
        const SizedBox(width: 8),
        const Expanded(child: Text('The courier confirmed the code. Delivered.')),
      ]);
    }
    final code = ref.watch(courierDeliveryCodeProvider(r.id)).value;
    if (code == null) {
      return Text(
        courierCodeHelp(config),
        key: const ValueKey('courier-code-sent'),
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      );
    }
    return Column(
      key: const ValueKey('courier-code-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Confirmation code', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Row(children: [
          for (final d in code.split(''))
            Container(
              margin: const EdgeInsets.only(right: 8),
              width: 40,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.colorScheme.outlineVariant),
              ),
              child: Text(d, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            ),
        ]),
        const SizedBox(height: 6),
        Text(
          courierCodeHelp(config),
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The courier types in the recipient's code; true once the server took it.
class CourierCodeDialog extends ConsumerStatefulWidget {
  const CourierCodeDialog({super.key, required this.rideId});
  final String rideId;

  @override
  ConsumerState<CourierCodeDialog> createState() => _CourierCodeDialogState();
}

class _CourierCodeDialogState extends ConsumerState<CourierCodeDialog> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!courierCodeOk(_code.text) || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = courierCodeMessage(await ref.read(courierCodeCheckProvider)(widget.rideId, _code.text.trim()));
    } catch (e) {
      error = errorText(e);
    }
    if (!mounted) return;
    if (error == null) return Navigator.pop(context, true);
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('courier-code-dialog'),
    title: const Text('Enter the confirmation code'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('Ask the recipient for the 4-digit code. Hand over the parcel once it is right.'),
      const SizedBox(height: 12),
      CodeField(
        key: const ValueKey('courier-code-field'),
        controller: _code,
        length: 4,
        errorText: _error,
        onChanged: (_) => setState(() => _error = null),
      ),
    ]),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _code,
        builder: (_, v, _) => FilledButton(
          key: const ValueKey('courier-code-confirm'),
          onPressed: _busy || !courierCodeOk(v.text) ? null : _submit,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Confirm'),
        ),
      ),
    ],
  );
}
