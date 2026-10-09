/// Keyboard dismissal for the whole app: a text field gives up focus — and
/// the keyboard goes away — when the user taps anywhere outside it, and when
/// the screen changes. Flutter's default does neither on a phone, so a
/// search field's keyboard used to stay up over the next screens.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Closes the keyboard (clears the focused text field), if any.
void dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

/// Whether a press from [down] to [up] was a tap rather than a scroll or a
/// drag: scrolling a list past a field keeps the keyboard up, so the user can
/// read the results while still typing.
bool isTapOutside(Offset down, Offset up, {double slop = kTouchSlop}) => (up - down).distance <= slop;

/// Unfocuses a text field on a tap outside it (not on a scroll), app-wide.
/// Wraps the app, overriding the text fields' tap-outside intents.
class KeyboardDismissOnTap extends StatefulWidget {
  const KeyboardDismissOnTap({super.key, required this.child});
  final Widget child;

  @override
  State<KeyboardDismissOnTap> createState() => _KeyboardDismissOnTapState();
}

class _KeyboardDismissOnTapState extends State<KeyboardDismissOnTap> {
  Offset? _down;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      EditableTextTapOutsideIntent: CallbackAction<EditableTextTapOutsideIntent>(
        onInvoke: (i) {
          _down = i.pointerDownEvent.position;
          return null;
        },
      ),
      EditableTextTapUpOutsideIntent: CallbackAction<EditableTextTapUpOutsideIntent>(
        onInvoke: (i) {
          final down = _down;
          _down = null;
          if (down != null && isTapOutside(down, i.pointerUpEvent.position)) i.focusNode.unfocus();
          return null;
        },
      ),
    },
    child: widget.child,
  );
}

/// Closes the keyboard whenever [listenable] (e.g. the router) notifies — a
/// screen change never carries a keyboard over to the next screen.
class KeyboardDismissOnChange extends StatefulWidget {
  const KeyboardDismissOnChange({super.key, required this.listenable, required this.child});
  final Listenable listenable;
  final Widget child;

  @override
  State<KeyboardDismissOnChange> createState() => _KeyboardDismissOnChangeState();
}

class _KeyboardDismissOnChangeState extends State<KeyboardDismissOnChange> {
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(dismissKeyboard);
  }

  @override
  void didUpdateWidget(KeyboardDismissOnChange old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(dismissKeyboard);
      widget.listenable.addListener(dismissKeyboard);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(dismissKeyboard);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
