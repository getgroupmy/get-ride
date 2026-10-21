/// How an incoming-offer card moves, in every module: the one place the
/// motion lives (locked by the owner; see CLAUDE.md, "Offer cards move the
/// same way everywhere").
///
/// - In: a new offer slides in from the right edge, right to left, into its
///   place with a small overshoot ([offerMotionInDuration]).
/// - Out: an offer that is declined, expires, is withdrawn or is taken
///   slides off to the left, tilting about −6° ([offerMotionTiltDegrees]) and
///   fading ([offerMotionOutDuration]).
/// - Reduced motion (the system's "remove animations"): no slide and no
///   tilt; the card only fades.
///
/// Use [OfferMotion] for one card, [OfferMotionList] for a column of cards
/// that come and go, [OfferMotionSwitcher] for one card slot whose offer is
/// replaced, or [offerMotionIn] / [offerMotionOut] with [OfferMotionTransform]
/// for a card that also follows a finger (the rider's OfferStack).
/// `test/offer_motion_test.dart` fails when these constants change or an
/// offer card animates on its own.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// How long a new offer takes to slide in.
const offerMotionInDuration = Duration(milliseconds: 460);

/// How long an offer takes to slide out.
const offerMotionOutDuration = Duration(milliseconds: 340);

/// Where a new offer starts, as a share of its own width: one full width to
/// the right (just off the right edge), so it moves right to left.
const offerMotionInFrom = 1.0;

/// Where a leaving offer ends, as a share of its width: past the left edge.
const offerMotionOutTo = -1.15;

/// The tilt a leaving offer turns to, in degrees (negative: anticlockwise,
/// the top leaning left as it goes).
const offerMotionTiltDegrees = -6.0;

/// [offerMotionTiltDegrees] in radians.
const offerMotionTilt = offerMotionTiltDegrees * math.pi / 180;

/// The way in: fast, past its place by a little, then back (the sample's
/// `cubic-bezier(.2, 1.4, .4, 1)`).
const offerMotionInCurve = Cubic(0.2, 1.4, 0.4, 1.0);

/// The way out: gathering speed as it goes.
const offerMotionOutCurve = Curves.easeInCubic;

/// One frame of an offer card's motion.
@immutable
class OfferMotionFrame {
  const OfferMotionFrame({this.dx = 0, this.angle = 0, this.opacity = 1});

  /// Sideways, as a share of the card's width (negative is left).
  final double dx;

  /// Rotation, in radians.
  final double angle;
  final double opacity;

  static const rest = OfferMotionFrame();

  @override
  bool operator ==(Object other) =>
      other is OfferMotionFrame && other.dx == dx && other.angle == angle && other.opacity == opacity;

  @override
  int get hashCode => Object.hash(dx, angle, opacity);

  @override
  String toString() => 'OfferMotionFrame(dx: $dx, angle: $angle, opacity: $opacity)';
}

/// The card coming in, at [t] (0 → 1 over [offerMotionInDuration]). [drag]
/// is how far a finger has pulled it, as a share of its width (negative is
/// left); the card tilts with the finger, up to [offerMotionTilt]. Pure.
OfferMotionFrame offerMotionIn(double t, {bool reduceMotion = false, double drag = 0}) {
  final v = t.clamp(0.0, 1.0);
  final fade = Curves.easeOut.transform((v / 0.6).clamp(0.0, 1.0));
  if (reduceMotion) return OfferMotionFrame(dx: drag, opacity: fade);
  final p = offerMotionInCurve.transform(v);
  final tilt = drag < 0 ? (drag * 4 * offerMotionTilt.abs()).clamp(offerMotionTilt, 0.0) : 0.0;
  return OfferMotionFrame(dx: (1 - p) * offerMotionInFrom + drag, angle: tilt, opacity: fade);
}

/// The card going out, at [t] (0 → 1 over [offerMotionOutDuration]). [from]
/// is where it was when it began to leave, as a share of its width (a swiped
/// card flies on from where the finger let go). Pure.
OfferMotionFrame offerMotionOut(double t, {bool reduceMotion = false, double from = 0}) {
  final v = t.clamp(0.0, 1.0);
  final p = offerMotionOutCurve.transform(v);
  final opacity = (1 - Curves.easeIn.transform(v)).clamp(0.0, 1.0);
  if (reduceMotion) return OfferMotionFrame(dx: from, opacity: opacity);
  final startTilt = from < 0 ? (from * 4 * offerMotionTilt.abs()).clamp(offerMotionTilt, 0.0) : 0.0;
  return OfferMotionFrame(
    dx: from + p * (offerMotionOutTo - from),
    angle: startTilt + p * (offerMotionTilt - startTilt),
    opacity: opacity,
  );
}

/// Whether the system asks for less motion.
bool offerReduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Draws [child] at [frame].
class OfferMotionTransform extends StatelessWidget {
  const OfferMotionTransform({super.key, required this.frame, required this.child});
  final OfferMotionFrame frame;
  final Widget child;

  // Always the same three layers, so the card (and a drag on it) keeps its
  // state from frame to frame.
  @override
  Widget build(BuildContext context) => FractionalTranslation(
    translation: Offset(frame.dx, 0),
    child: Transform.rotate(
      angle: frame.angle,
      alignment: Alignment.bottomCenter,
      child: Opacity(opacity: frame.opacity.clamp(0.0, 1.0), child: child),
    ),
  );
}

/// One offer card: slides in when first built and out once [leaving] turns
/// true, then calls [onGone].
class OfferMotion extends StatefulWidget {
  const OfferMotion({super.key, required this.child, this.leaving = false, this.onGone, this.animateIn = true});
  final Widget child;
  final bool leaving;
  final VoidCallback? onGone;

  /// False shows the card in place at once (a card that was already on screen).
  final bool animateIn;

  @override
  State<OfferMotion> createState() => _OfferMotionState();
}

class _OfferMotionState extends State<OfferMotion> with TickerProviderStateMixin {
  late final _in = AnimationController(vsync: this, duration: offerMotionInDuration);
  late final _out = AnimationController(vsync: this, duration: offerMotionOutDuration);

  @override
  void initState() {
    super.initState();
    widget.animateIn ? _in.forward() : _in.value = 1;
    if (widget.leaving) _goOut();
  }

  void _goOut() => _out.forward().whenComplete(() {
    if (mounted) widget.onGone?.call();
  });

  @override
  void didUpdateWidget(covariant OfferMotion old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      _goOut();
    } else if (!widget.leaving && old.leaving) {
      // Still offered after all.
      _out.value = 0;
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_in, _out]),
    builder: (context, child) {
      final reduce = offerReduceMotion(context);
      final frame = _out.value > 0
          ? offerMotionOut(_out.value, reduceMotion: reduce)
          : offerMotionIn(_in.value, reduceMotion: reduce);
      return IgnorePointer(
        ignoring: widget.leaving,
        child: OfferMotionTransform(frame: frame, child: child!),
      );
    },
    child: widget.child,
  );
}

/// A column of offer cards that come and go: each child needs a [Key]. A new
/// key slides in; a key no longer given stays long enough to slide out. The
/// cards first given are shown in place unless [animateFirst].
class OfferMotionList extends StatefulWidget {
  const OfferMotionList({super.key, required this.children, this.animateFirst = true, this.gap = 0});
  final List<Widget> children;
  final bool animateFirst;
  final double gap;

  @override
  State<OfferMotionList> createState() => _OfferMotionListState();
}

class _OfferMotionListState extends State<OfferMotionList> {
  /// What is on screen, in order: (key, widget, leaving, animate in).
  final _items = <({Key key, Widget child, bool leaving, bool animateIn})>[];

  @override
  void initState() {
    super.initState();
    for (final c in widget.children) {
      _items.add((key: c.key!, child: c, leaving: false, animateIn: widget.animateFirst));
    }
  }

  @override
  void didUpdateWidget(covariant OfferMotionList old) {
    super.didUpdateWidget(old);
    final now = {for (final c in widget.children) c.key!: c};
    for (var i = 0; i < _items.length; i++) {
      final e = _items[i];
      final fresh = now[e.key];
      _items[i] = (key: e.key, child: fresh ?? e.child, leaving: fresh == null, animateIn: e.animateIn);
    }
    final known = {for (final e in _items) e.key};
    var at = 0;
    for (final c in widget.children) {
      final k = c.key!;
      final i = _items.indexWhere((e) => e.key == k);
      if (i >= 0) {
        at = i + 1;
        continue;
      }
      if (known.add(k)) {
        _items.insert(at, (key: k, child: c, leaving: false, animateIn: true));
        at++;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final e in _items)
        Padding(
          key: ValueKey(('offer-motion', e.key)),
          padding: EdgeInsets.only(bottom: widget.gap),
          child: OfferMotion(
            leaving: e.leaving,
            animateIn: e.animateIn,
            onGone: () => setState(() => _items.removeWhere((x) => x.key == e.key && x.leaving)),
            child: e.child,
          ),
        ),
    ],
  );
}

/// One card slot whose offer is replaced: the new one (a new [child] key)
/// slides in from the right while the old one slides out to the left.
class OfferMotionSwitcher extends StatelessWidget {
  const OfferMotionSwitcher({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduce = offerReduceMotion(context);
    final current = child.key;
    return AnimatedSwitcher(
      duration: offerMotionInDuration,
      reverseDuration: offerMotionOutDuration,
      layoutBuilder: (top, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?top]),
      transitionBuilder: (c, animation) => AnimatedBuilder(
        animation: animation,
        // A leaving child's animation runs 1 → 0.
        builder: (context, inner) => OfferMotionTransform(
          frame: c.key == current
              ? offerMotionIn(animation.value, reduceMotion: reduce)
              : offerMotionOut(1 - animation.value, reduceMotion: reduce),
          child: inner!,
        ),
        child: c,
      ),
      child: child,
    );
  }
}
