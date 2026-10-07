// Buttons, switches and rows that show they are working.
//
// Tapped, each one runs its action; if the action returns a Future (it talks
// to the backend, opens a picker, waits for an answer) the control shows a
// spinner and takes no more taps until the Future completes, so an action
// can't be sent twice and the user can see something is happening. A
// synchronous action (navigate, close) behaves exactly like the plain
// widget.
import 'dart:async';

import 'package:flutter/material.dart';

/// What a busy control runs: anything, sync or async.
typedef BusyAction = FutureOr<void> Function();

/// The spinner a busy control shows, sized to sit where its label or icon was.
class BusySpinner extends StatelessWidget {
  const BusySpinner({super.key, this.size = 18, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: const ValueKey('busy-spinner'),
    dimension: size,
    child: CircularProgressIndicator(strokeWidth: 2, color: color),
  );
}

/// Runs [action], tracking whether it is still going. Shared by every busy
/// control; a second tap while one is running is ignored.
mixin _Busy<T extends StatefulWidget> on State<T> {
  bool busy = false;

  Future<void> runBusy(BusyAction action) async {
    if (busy) return;
    final result = action();
    if (result is! Future) return;
    setState(() => busy = true);
    try {
      await result;
    } catch (e, s) {
      // The action should report its own failure (a snackbar); one that
      // doesn't still frees the control.
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: s, library: 'busy controls'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

enum _ButtonKind { filled, tonal, outlined, text }

/// A Material button (filled, tonal, outlined or text) whose label turns into
/// a spinner while its action runs. The button keeps its size.
class BusyButton extends StatefulWidget {
  const BusyButton.filled({super.key, required this.onPressed, required this.child, this.style, this.icon})
    : _kind = _ButtonKind.filled;
  const BusyButton.tonal({super.key, required this.onPressed, required this.child, this.style, this.icon})
    : _kind = _ButtonKind.tonal;
  const BusyButton.outlined({super.key, required this.onPressed, required this.child, this.style, this.icon})
    : _kind = _ButtonKind.outlined;
  const BusyButton.text({super.key, required this.onPressed, required this.child, this.style, this.icon})
    : _kind = _ButtonKind.text;

  final BusyAction? onPressed;
  final Widget child;
  final ButtonStyle? style;

  /// A leading icon (the `.icon` constructors of the plain buttons).
  final Widget? icon;
  final _ButtonKind _kind;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> with _Busy {
  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed == null || busy ? null : () => runBusy(widget.onPressed!);
    // The label stays (invisible) so the button keeps its width.
    final label = busy
        ? Stack(
            alignment: Alignment.center,
            children: [
              Opacity(opacity: 0, child: widget.child),
              const BusySpinner(),
            ],
          )
        : widget.child;
    final icon = widget.icon;
    return switch (widget._kind) {
      _ButtonKind.filled =>
        icon == null
            ? FilledButton(onPressed: onPressed, style: widget.style, child: label)
            : FilledButton.icon(onPressed: onPressed, style: widget.style, icon: icon, label: label),
      _ButtonKind.tonal =>
        icon == null
            ? FilledButton.tonal(onPressed: onPressed, style: widget.style, child: label)
            : FilledButton.tonalIcon(onPressed: onPressed, style: widget.style, icon: icon, label: label),
      _ButtonKind.outlined =>
        icon == null
            ? OutlinedButton(onPressed: onPressed, style: widget.style, child: label)
            : OutlinedButton.icon(onPressed: onPressed, style: widget.style, icon: icon, label: label),
      _ButtonKind.text =>
        icon == null
            ? TextButton(onPressed: onPressed, style: widget.style, child: label)
            : TextButton.icon(onPressed: onPressed, style: widget.style, icon: icon, label: label),
    };
  }
}

/// An [IconButton] whose icon turns into a spinner while its action runs.
class BusyIconButton extends StatefulWidget {
  const BusyIconButton({super.key, required this.onPressed, required this.icon, this.tooltip, this.color});
  final BusyAction? onPressed;
  final Widget icon;
  final String? tooltip;
  final Color? color;

  @override
  State<BusyIconButton> createState() => _BusyIconButtonState();
}

class _BusyIconButtonState extends State<BusyIconButton> with _Busy {
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.tooltip,
    color: widget.color,
    onPressed: widget.onPressed == null || busy ? null : () => runBusy(widget.onPressed!),
    icon: busy ? const BusySpinner(size: 20) : widget.icon,
  );
}

/// A [SwitchListTile] that, while the change is being saved, greys out and
/// shows a spinner in place of its leading icon; it takes no other change
/// until the first is done. [value] is what is saved: the caller flips it
/// when [onChanged] completes.
class BusySwitchListTile extends StatefulWidget {
  const BusySwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.isThreeLine = false,
    this.dense,
    this.contentPadding,
  });

  final bool value;
  final FutureOr<void> Function(bool)? onChanged;
  final Widget? title, subtitle, secondary;
  final bool isThreeLine;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;

  @override
  State<BusySwitchListTile> createState() => _BusySwitchListTileState();
}

class _BusySwitchListTileState extends State<BusySwitchListTile> with _Busy {
  @override
  Widget build(BuildContext context) => SwitchListTile(
    value: widget.value,
    onChanged: widget.onChanged == null || busy ? null : (v) => runBusy(() => widget.onChanged!(v)),
    title: widget.title,
    subtitle: widget.subtitle,
    secondary: busy ? const BusySpinner(size: 24) : widget.secondary,
    isThreeLine: widget.isThreeLine,
    dense: widget.dense,
    contentPadding: widget.contentPadding,
  );
}

/// A [Switch] that is replaced by a spinner while the change is saved.
class BusySwitch extends StatefulWidget {
  const BusySwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final FutureOr<void> Function(bool)? onChanged;

  @override
  State<BusySwitch> createState() => _BusySwitchState();
}

class _BusySwitchState extends State<BusySwitch> with _Busy {
  @override
  Widget build(BuildContext context) => busy
      ? const SizedBox(width: 52, height: 32, child: Center(child: BusySpinner(size: 22)))
      : Switch(
          value: widget.value,
          onChanged: widget.onChanged == null ? null : (v) => runBusy(() => widget.onChanged!(v)),
        );
}

/// A [ListTile] whose trailing widget turns into a spinner while its tap
/// action runs (a row that saves or loads something when tapped).
class BusyListTile extends StatefulWidget {
  const BusyListTile({
    super.key,
    required this.onTap,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.dense,
    this.enabled = true,
    this.isThreeLine = false,
    this.contentPadding,
  });

  final BusyAction? onTap;
  final Widget? leading, title, subtitle, trailing;
  final bool? dense;
  final bool enabled;
  final bool isThreeLine;
  final EdgeInsetsGeometry? contentPadding;

  @override
  State<BusyListTile> createState() => _BusyListTileState();
}

class _BusyListTileState extends State<BusyListTile> with _Busy {
  @override
  Widget build(BuildContext context) => ListTile(
    leading: widget.leading,
    title: widget.title,
    subtitle: widget.subtitle,
    dense: widget.dense,
    isThreeLine: widget.isThreeLine,
    contentPadding: widget.contentPadding,
    enabled: widget.enabled && !busy,
    trailing: busy ? const BusySpinner(size: 22) : widget.trailing,
    onTap: widget.onTap == null || busy ? null : () => runBusy(widget.onTap!),
  );
}
