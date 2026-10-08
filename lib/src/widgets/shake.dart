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

  /// Where the shake has [child] now, sideways (0 at rest).
  Animation<double> get offset => _x;

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

/// Something inside a [Shake] that swings the other way as it shakes, but
/// never further than [travel] from where it rests: an inner card inside its
/// tray, kept within the tray's padding however hard the tray is shaken.
class ShakeCounter extends StatelessWidget {
  const ShakeCounter({super.key, required this.travel, required this.child});

  /// The furthest it moves from rest, either way (inside the [Shake]).
  final double travel;
  final Widget child;

  /// Its offset, inside the [Shake], when the [Shake] is [x] out: the other
  /// way, scaled so the [Shake]'s widest swing takes it exactly [travel].
  static double counter(double x, double travel) {
    final widest = Shake.offsets.map((o) => o.abs()).reduce((a, b) => a > b ? a : b);
    return (-x * travel / widest).clamp(-travel, travel);
  }

  @override
  Widget build(BuildContext context) {
    final shake = Shake.maybeOf(context);
    if (shake == null) return child;
    return AnimatedBuilder(
      animation: shake.offset,
      builder: (context, child) =>
          Transform.translate(offset: Offset(counter(shake.offset.value, travel), 0), child: child),
      child: child,
    );
  }
}
