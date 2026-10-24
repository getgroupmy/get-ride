// Messages to the user: always a modal with an OK, never a bar at the bottom
// (owner rule: all popups are modals). Every notice goes through
// [showAppNotice] with an id ('notice.<area>'), so it is listed in App Page
// Settings like any other modal (page_inventory_scan.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'page_style_host.dart';

/// How a notice reads: its icon and colour.
enum NoticeKind { info, success, error }

/// The notice on screen, replaced by the next one so repeats never stack.
Route<void>? _shown;

/// [message] as a modal with an OK (and [actionLabel] as a second button,
/// running [onAction] once the modal is closed). [id] is the notice's area,
/// `notice.<area>`, listed in App Page Settings; [key] is the dialog's, for
/// tests.
///
/// The modal opens after the next frame, so a caller that closes its own
/// sheet or page, or moves to another, right after (`showInfo(...);
/// Navigator.pop(...)`) does that, and the notice opens on top. Completes
/// when the notice is closed.
Future<void> showAppNotice({
  required String id,
  required BuildContext context,
  required String message,
  String? title,
  NoticeKind kind = NoticeKind.info,
  String? actionLabel,
  VoidCallback? onAction,
  Key? key,
}) {
  final done = Completer<void>();
  final root = context.mounted ? Navigator.maybeOf(context, rootNavigator: true) : null;
  // After the caller's own steps: a pop, a push or a `go` right after this
  // runs first, and the notice opens over the page they lead to.
  SchedulerBinding.instance.addPostFrameCallback((_) {
    final at = context.mounted ? context : root?.context;
    // Nowhere to open it: a widget above the app's pages passes the router's
    // navigator context instead.
    if (at == null || !at.mounted || Navigator.maybeOf(at, rootNavigator: true) == null) {
      done.complete();
      return;
    }
    final old = _shown;
    if (old != null && old.isActive) old.navigator?.removeRoute(old);
    var action = false;
    final closed = showAppDialog<void>(
      id: id,
      context: at,
      builder: (c) => NoticeDialog(
        key: key ?? const ValueKey('notice'),
        message: message,
        title: title,
        kind: kind,
        actionLabel: actionLabel,
        onAction: actionLabel == null
            ? null
            : () {
                action = true;
                Navigator.pop(c);
              },
      ),
    );
    // The route just pushed: the top one.
    Route<void>? mine;
    Navigator.of(at, rootNavigator: true).popUntil((r) {
      mine = r;
      return true;
    });
    _shown = mine;
    closed.whenComplete(() {
      if (identical(_shown, mine)) _shown = null;
      if (!done.isCompleted) done.complete();
      if (action) onAction?.call();
    });
  });
  SchedulerBinding.instance.ensureVisualUpdate();
  return done.future;
}

/// The notice itself: an icon by [kind], the message, OK.
class NoticeDialog extends StatelessWidget {
  const NoticeDialog({
    super.key = const ValueKey('notice'),
    required this.message,
    this.title,
    this.kind = NoticeKind.info,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? title;
  final NoticeKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (kind) {
      NoticeKind.info => (Icons.info_outline, cs.primary),
      NoticeKind.success => (Icons.check_circle_outline, cs.primary),
      NoticeKind.error => (Icons.error_outline, cs.error),
    };
    return AlertDialog(
      icon: Icon(icon, color: color),
      title: title == null ? null : Text(title!, textAlign: TextAlign.center),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        if (actionLabel != null && onAction != null)
          TextButton(key: const ValueKey('notice-action'), onPressed: onAction, child: Text(actionLabel!)),
        FilledButton(
          key: const ValueKey('notice-ok'),
          onPressed: () => Navigator.pop(context),
          child: Text(actionLabel != null && onAction != null ? 'Close' : 'OK'),
        ),
      ],
    );
  }
}
