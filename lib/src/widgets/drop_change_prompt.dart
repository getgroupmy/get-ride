import 'package:material_ui/material_ui.dart';

import '../core/drop_change.dart' show DropChangeKind;
import 'page_style_host.dart';

/// The popup the driver answers when the passenger asks to move the drop-off
/// mid-ride (migration 0341): the new destination, the new fare and the
/// change on the old one, with Reject / Accept. It can't be dismissed by
/// tapping outside: the change waits on the answer.
class DropChangeRequestDialog extends StatelessWidget {
  const DropChangeRequestDialog({
    super.key,
    required this.newAddress,
    required this.oldFare,
    required this.newFare,
    required this.fareText,
  });

  final String newAddress;
  final double? oldFare;
  final double? newFare;
  final String Function(num?) fareText;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final delta = (oldFare != null && newFare != null) ? newFare! - oldFare! : null;
    final deltaText = delta == null
        ? null
        : '${delta >= 0 ? '+' : '−'}${fareText(delta.abs())}';
    return AlertDialog(
      key: const ValueKey('drop-change-dialog'),
      icon: Icon(Icons.edit_location_alt_outlined, color: t.colorScheme.primary),
      title: const Text('Change drop-off?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('The passenger wants to change the drop-off to:', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(newAddress, textAlign: TextAlign.center, style: t.textTheme.titleSmall),
          if (oldFare != null && newFare != null) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  fareText(oldFare),
                  style: t.textTheme.titleMedium?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward, size: 18),
                const SizedBox(width: 8),
                Text(fareText(newFare), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            if (deltaText != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(deltaText, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(
          key: const ValueKey('drop-change-reject'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Reject'),
        ),
        FilledButton(
          key: const ValueKey('drop-change-accept'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Accept'),
        ),
      ],
    );
  }
}

/// Shows [DropChangeRequestDialog] once for each pending change, and closes it
/// by itself when the change goes (accepted, rejected, withdrawn or the window
/// lapsing), so a stale question never stays on screen. Mirrors
/// [CancelRequestPrompt].
class DropChangePrompt {
  DateTime? _askedAt;
  BuildContext? _open;

  /// Call with each update of the ride: [askedAt] is when the passenger asked
  /// (the pending change's timestamp), null when nothing is pending.
  void update(
    BuildContext context, {
    required DateTime? askedAt,
    required String newAddress,
    required double? oldFare,
    required double? newFare,
    required String Function(num?) fareText,
    required Future<void> Function() onAccept,
    required Future<void> Function() onReject,
  }) {
    if (askedAt == null) {
      _close();
      _askedAt = null;
      return;
    }
    if (askedAt == _askedAt) return; // already asking about this one
    _close();
    _askedAt = askedAt;
    showAppDialog<bool>(
      id: 'partner.drop-change',
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _open = ctx;
        return PopScope(
          canPop: false,
          child: DropChangeRequestDialog(
            newAddress: newAddress,
            oldFare: oldFare,
            newFare: newFare,
            fareText: fareText,
          ),
        );
      },
    ).then((accept) {
      _open = null;
      if (accept == true) {
        onAccept();
      } else if (accept == false) {
        onReject();
      }
    });
  }

  void _close() {
    final open = _open;
    _open = null;
    if (open != null && open.mounted) Navigator.of(open).pop();
  }
}

/// The passenger's review before a drop-off change is sent (0341): the new
/// place, the old → new fare (the one fare when it stays as it is), and
/// whether it applies at once or waits for the driver. The fare and that
/// answer are the server's (0431).
class DropChangeReviewDialog extends StatelessWidget {
  const DropChangeReviewDialog({
    super.key,
    required this.oldLabel,
    required this.newLabel,
    required this.oldFare,
    required this.newFare,
    required this.fareText,
    required this.kind,
  });

  final String oldLabel, newLabel;
  final double oldFare, newFare;
  final String Function(num?) fareText;
  final DropChangeKind kind;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final delta = newFare - oldFare;
    final deltaText = '${delta >= 0 ? '+' : '−'}${fareText(delta.abs())}';
    final instant = kind == DropChangeKind.instant;
    // The fare stays where the server has nothing to price the change on.
    final sameFare = delta.abs() < 0.005;
    return AlertDialog(
      key: const ValueKey('drop-change-review-dialog'),
      icon: Icon(Icons.edit_location_alt_outlined, color: t.colorScheme.primary),
      title: const Text('Change drop-off'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.location_on_outlined),
            title: Text(newLabel),
            subtitle: Text('was $oldLabel'),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (!sameFare) ...[
                Text(
                  fareText(oldFare),
                  style: t.textTheme.titleMedium?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward, size: 18),
                const SizedBox(width: 8),
              ],
              Text(fareText(newFare), style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              if (!sameFare) ...[
                const SizedBox(width: 8),
                Text(deltaText, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(
            sameFare
                ? (instant
                    ? 'The fare stays the same. This applies straight away.'
                    : 'The fare stays the same. Your driver needs to accept the new drop-off first.')
                : (instant
                    ? 'This applies straight away.'
                    : 'Your driver needs to accept the new drop-off and fare first.'),
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('drop-change-review-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep original'),
        ),
        FilledButton(
          key: const ValueKey('drop-change-review-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(instant ? 'Change drop-off' : 'Request change'),
        ),
      ],
    );
  }
}
