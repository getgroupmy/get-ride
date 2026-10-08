import 'package:flutter/material.dart';

/// A sideways shake of [child], as Expo's `triggerShake`: 8, −8, 6, −6, 0
/// pixels, 50 ms a step. Something below it calls [Shake.maybeOf] to say
/// "no" without words (a fare stepped past its limit).
class Shake extends StatefulWidget {
  const Shake({super.key, required this.child});

  final Widget child;

  /// The offsets, in order, each reached in [step].
  static const offsets = [8.0, -8.0, 6.0, -6.0, 0.0];
  static const step = Duration(milliseconds: 50);

  /// The nearest [Shake] above [context], if any.
  static ShakeState? maybeOf(BuildContext context) => context.findAncestorStateOfType<ShakeState>();

  @override
  State<Shake> createState() => ShakeState();
}

class ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Shake.step * Shake.offsets.length);
  late final Animation<double> _x = TweenSequence<double>([
    for (var i = 0; i < Shake.offsets.length; i++)
      TweenSequenceItem(tween: Tween(begin: i == 0 ? 0.0 : Shake.offsets[i - 1], end: Shake.offsets[i]), weight: 1),
  ]).animate(_c);

  /// Runs the shake from the start.
  void shake() => _c.forward(from: 0);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _x,
    builder: (context, child) => Transform.translate(offset: Offset(_x.value, 0), child: child),
    child: widget.child,
  );
}
