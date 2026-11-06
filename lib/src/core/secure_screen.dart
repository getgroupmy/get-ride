// Keeps a screen's contents out of screenshots and screen recordings while
// it is on display — used for the approver's document review, where other
// people's ID and licence images must not leave the device.
//
// Platform reality (stated plainly so the UI never over-promises):
//   * Android — FLAG_SECURE blanks the window in screenshots AND screen
//     recordings, and blocks the screenshot gesture. Fully enforced.
//   * iOS — an app cannot block a screenshot (no OS API). It CAN hide its
//     content while the screen is being recorded or mirrored
//     (UIScreen.isCaptured), which this does; a still screenshot is not
//     preventable and can only be detected.
//   * web / desktop — no API to block capture; this is a no-op.
//
// The native side is a method channel (get_ride/secure_screen) with `on` /
// `off`. A reference count means several secured screens (a page and a dialog
// over it) compose correctly, and the flag is only cleared once the last one
// leaves.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('get_ride/secure_screen');
int _active = 0;

Future<void> _apply(bool on) async {
  try {
    await _channel.invokeMethod<void>(on ? 'on' : 'off');
  } catch (_) {
    // No implementation on this platform (web/desktop): capture can't be
    // blocked here, and the review screen still works.
  }
}

void _acquire() {
  _active++;
  if (_active == 1) _apply(true);
}

void _release() {
  if (_active == 0) return;
  _active--;
  if (_active == 0) _apply(false);
}

/// Wrap a screen's body in this to block screen capture while it is mounted.
/// Safe to nest (a dialog over a page); capture is re-allowed only when the
/// last [SecureScreen] is disposed.
class SecureScreen extends StatefulWidget {
  const SecureScreen({super.key, required this.child});

  final Widget child;

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  @override
  void initState() {
    super.initState();
    _acquire();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
