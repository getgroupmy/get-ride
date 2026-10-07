import 'package:flutter/material.dart';

/// The popup either side of a ride answers when the other asks to cancel:
/// the request, and Decline / Approve. It can't be dismissed by tapping
/// outside it: the ride waits on the answer.
class CancelRequestDialog extends StatelessWidget {
  const CancelRequestDialog({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('cancel-request-dialog'),
    icon: Icon(Icons.cancel_outlined, color: Theme.of(context).colorScheme.error),
    title: const Text('Cancel this ride?'),
    content: Text(message, textAlign: TextAlign.center),
    actionsAlignment: MainAxisAlignment.center,
    actions: [
      OutlinedButton(
        key: const ValueKey('cancel-request-decline'),
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Decline'),
      ),
      FilledButton(
        key: const ValueKey('cancel-request-approve'),
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Approve'),
      ),
    ],
  );
}

/// Shows [CancelRequestDialog] once for each request to cancel, and closes
/// it by itself when the request goes (withdrawn, answered elsewhere, or
/// the ride ended), so a stale question never stays on screen.
class CancelRequestPrompt {
  DateTime? _askedAt;
  BuildContext? _open;

  /// Call with each update of the ride: [askedAt] is when the other side
  /// asked, null when nobody is asking.
  void update(
    BuildContext context, {
    required DateTime? askedAt,
    required String message,
    required Future<void> Function() onApprove,
    required Future<void> Function() onDecline,
  }) {
    if (askedAt == null) {
      _close();
      _askedAt = null;
      return;
    }
    if (askedAt == _askedAt) return; // already asked about this one
    _close();
    _askedAt = askedAt;
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _open = ctx;
        return PopScope(canPop: false, child: CancelRequestDialog(message: message));
      },
    ).then((approve) {
      _open = null;
      if (approve == true) {
        onApprove();
      } else if (approve == false) {
        onDecline();
      }
    });
  }

  void _close() {
    final open = _open;
    _open = null;
    if (open != null && open.mounted) Navigator.of(open).pop();
  }
}
