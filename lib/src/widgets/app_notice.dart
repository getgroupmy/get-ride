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

/// Admin → Display → Popups → Close popups after (`popupAutoCloseSeconds`):
/// every notice closes itself this long after it opens, as if its (x) was
/// tapped. Zero keeps it open until it is closed. The app sets it from the
/// display settings (app.dart), live as the admin changes it.
final noticeAutoClose = ValueNotifier<Duration>(Duration.zero);

/// [message] as a modal with an OK (and [actionLabel] as a second button,
/// running [onAction] once the modal is closed; the other button then reads
/// Close, or [closeLabel]). [id] is the notice's area,
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
  String? closeLabel,
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
        autoClose: noticeAutoClose.value,
        actionLabel: actionLabel,
        closeLabel: closeLabel,
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

/// The notice itself: an icon by [kind] with an (x) beside it, the message,
/// OK. With [autoClose] it closes itself after that long, a bar under the
/// message showing the time left.
class NoticeDialog extends StatefulWidget {
  const NoticeDialog({
    super.key = const ValueKey('notice'),
    required this.message,
    this.title,
    this.kind = NoticeKind.info,
    this.autoClose = Duration.zero,
    this.actionLabel,
    this.onAction,
    this.closeLabel,
  });

  final String message;
  final String? title;
  final NoticeKind kind;
  final Duration autoClose;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// The closing button's label in place of OK (Close beside an action).
  final String? closeLabel;

  @override
  State<NoticeDialog> createState() => _NoticeDialogState();
}

class _NoticeDialogState extends State<NoticeDialog> with SingleTickerProviderStateMixin {
  /// The time left, 1 to 0, while it closes by itself.
  AnimationController? _left;

  @override
  void initState() {
    super.initState();
    if (widget.autoClose > Duration.zero) {
      _left = AnimationController(vsync: this, duration: widget.autoClose, value: 1)
        ..addStatusListener((s) {
          if (s == AnimationStatus.dismissed && mounted) Navigator.maybePop(context);
        })
        ..reverse();
    }
  }

  @override
  void dispose() {
    _left?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (widget.kind) {
      NoticeKind.info => (Icons.info_outline, cs.primary),
      NoticeKind.success => (Icons.check_circle_outline, cs.primary),
      NoticeKind.error => (Icons.error_outline, cs.error),
    };
    final left = _left;
    final action = widget.actionLabel != null && widget.onAction != null;
    return AlertDialog(
      // The kind's icon in the middle, the (x) at the end.
      icon: Row(children: [
        const SizedBox(width: 40),
        Expanded(child: Icon(icon, color: color)),
        IconButton(
          key: const ValueKey('notice-close'),
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ]),
      iconPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      title: widget.title == null ? null : Text(widget.title!, textAlign: TextAlign.center),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Flexible(child: SingleChildScrollView(child: Text(widget.message))),
        if (left != null) ...[
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: left,
            builder: (_, _) => LinearProgressIndicator(
              key: const ValueKey('notice-time-left'),
              value: left.value,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
              semanticsLabel: 'Closes by itself',
            ),
          ),
        ],
      ]),
      actions: [
        if (action)
          TextButton(key: const ValueKey('notice-action'), onPressed: widget.onAction, child: Text(widget.actionLabel!)),
        FilledButton(
          key: const ValueKey('notice-ok'),
          onPressed: () => Navigator.pop(context),
          child: Text(widget.closeLabel ?? (action ? 'Close' : 'OK')),
        ),
      ],
    );
  }
}
