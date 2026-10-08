import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Every bottom sheet in the app: rounded top corners and a handle to drag
/// it by (down to close; the tall ones also up to expand).
const appBottomSheetTheme = BottomSheetThemeData(
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
  clipBehavior: Clip.antiAlias,
  showDragHandle: true,
);

/// How much of a map a sheet floating over it covers, for the map's own
/// buttons, its credit and its camera to stay clear of. Absent (0) where
/// nothing covers the map.
class MapBottomInset extends InheritedWidget {
  const MapBottomInset({
    super.key,
    required this.extent,
    required this.height,
    required this.cap,
    this.pull,
    required super.child,
  });

  /// The sheet's size, as a fraction of [height].
  final ValueListenable<double> extent;
  final double height;

  /// The most the inset grows to: a sheet dragged higher simply covers the
  /// buttons, rather than pushing them off the top of the map.
  final double cap;

  /// How far the sheet is pulled down past fully down (its rubber band), so
  /// what sits on its top edge goes down with it and springs back with it.
  final ValueListenable<double>? pull;

  double get value => (height * extent.value - (pull?.value ?? 0)).clamp(0.0, cap);

  /// [build] with the current inset, rebuilt as the sheet moves.
  static Widget listen(BuildContext context, Widget Function(double inset) build) {
    final m = context.dependOnInheritedWidgetOfExactType<MapBottomInset>();
    if (m == null) return build(0);
    return ListenableBuilder(
      listenable: Listenable.merge([m.extent, ?m.pull]),
      builder: (_, _) => build(m.value),
    );
  }

  /// The inset right now (for a one-off camera fit).
  static double of(BuildContext context) => context.getInheritedWidgetOfExactType<MapBottomInset>()?.value ?? 0;

  @override
  bool updateShouldNotify(MapBottomInset old) =>
      old.extent != extent || old.pull != pull || old.height != height || old.cap != cap;
}

/// A map with a draggable sheet floating over it (phone layout): the map
/// fills the screen and the sheet, with rounded top corners and a handle,
/// is dragged up to expand rather than scrolled inside a fixed panel. The
/// map's buttons and credit ride above the sheet ([MapBottomInset]) until
/// it covers more than all but [mapMinFraction] of the screen.
class MapSheetLayout extends StatefulWidget {
  const MapSheetLayout({
    super.key,
    required this.map,
    required this.sheet,
    this.peek,
    this.initial = 0.45,
    this.min = 0.2,
    this.max = 0.92,
    this.mapMinFraction = 0.4,
    this.locked = false,
    this.hidden = false,
    this.footer,
    this.aboveFooter,
  });

  final Widget map;
  final Widget sheet;

  /// What the sheet shows when it is all the way down (the driver's online
  /// switch); [sheet] fades in below it as the sheet is dragged up, so a
  /// part-hidden card never peeks out from under the fold.
  final Widget? peek;
  final double initial, min, max;

  /// The least of the screen above the sheet the map's buttons follow it to.
  final double mapMinFraction;

  /// Holds the sheet down at [min]: it can't be dragged up and its content
  /// doesn't scroll, leaving the map to something on it (the driver's
  /// floating requests).
  final bool locked;

  /// Slides the sheet down out of sight (the map being dragged under the
  /// pickup pin), and back up where it was when this turns off. The map's
  /// [MapBottomInset] is left as it was, so nothing on the map shifts.
  final bool hidden;

  /// Pinned to the bottom of the screen over the sheet, whatever its size
  /// (the confirm screen's "Find a driver" bar, Expo's fixed bottom); the
  /// sheet's content gets room below it so nothing ends up hidden behind.
  final Widget? footer;

  /// Pinned just above [footer], and shown only while the sheet is up at
  /// [max]: it fades in as the sheet gets there and out as it leaves (the
  /// confirm screen's fare disclaimer, as Expo's shows only when expanded).
  final Widget? aboveFooter;

  /// How near [max] counts as up, for [aboveFooter].
  static const upSlack = 0.05;

  /// How long [aboveFooter] takes to fade in or out (Expo's 200 ms).
  static const fadeDuration = Duration(milliseconds: 200);

  /// How long the sheet takes to slide out of sight or back.
  static const hideDuration = Duration(milliseconds: 200);

  @override
  State<MapSheetLayout> createState() => _MapSheetLayoutState();
}

class _MapSheetLayoutState extends State<MapSheetLayout> with TickerProviderStateMixin {
  late final _extent = ValueNotifier<double>(widget.locked ? widget.min : widget.initial);
  final _sheet = DraggableScrollableController();

  /// How far the sheet is pulled past fully down, before resistance.
  double _pull = 0;

  /// The sheet's own rubber band (iOS-style): pulled down past fully down
  /// it follows the finger with growing resistance, and springs back when
  /// let go. The content inside never bounces.
  late final _bounce = AnimationController.unbounded(vsync: this);

  /// The [MapSheetLayout.footer]'s height, as last laid out.
  double _footerHeight = 0;

  /// The [MapSheetLayout.aboveFooter]'s height, as last laid out.
  double _aboveHeight = 0;

  /// The sheet's content scroller, as last built.
  ScrollController? _scroll;

  /// What [MapSheetReveal] keeps in view (the chosen vehicle), and whether
  /// the sheet has been dragged to a new height since it was last shown.
  BuildContext? _target;
  bool _moved = false;

  /// How far the content is slid up under the handle to bring [_target]
  /// into view while the sheet is below full height. Sliding rather than
  /// scrolling keeps a drag on the sheet moving the sheet: a sheet whose
  /// content is scrolled scrolls it back first.
  late final _shift = AnimationController.unbounded(vsync: this);

  bool get _full => _sheet.isAttached && _sheet.size >= widget.max - 0.001;

  /// At full height the content scrolls: a slide becomes the same scroll,
  /// so nothing moves on screen and the top is reachable again.
  void _foldShift() {
    final scroll = _scroll;
    if (_shift.value == 0 || scroll == null || !scroll.hasClients) return;
    final p = scroll.position;
    final to = (p.pixels + _shift.value).clamp(p.minScrollExtent, p.maxScrollExtent);
    _shift.stop();
    _shift.value = 0;
    scroll.jumpTo(to);
  }

  /// Brings [target] whole into the part of the sheet that shows, between
  /// its handle and the [MapSheetLayout.footer] (Expo moves the chosen
  /// vehicle above the fixed bottom the same way).
  void _reveal(BuildContext target) {
    final scroll = _scroll;
    final box = target.findRenderObject() as RenderBox?;
    final layout = context.findRenderObject() as RenderBox?;
    if (scroll == null || !scroll.hasClients || box == null || !box.attached || layout == null) return;
    if (!_sheet.isAttached || _hide.value > 0) return;
    if (_full) _foldShift();
    const margin = 8.0;
    final origin = layout.localToGlobal(Offset.zero).dy;
    final top = origin + layout.size.height * (1 - _sheet.size) + 22 + margin;
    // At full height the disclaimer stands over the foot of it as well.
    final bottom = origin + layout.size.height - _footerHeight - (_full ? _aboveHeight : 0) - margin;
    final card = box.localToGlobal(Offset.zero) & box.size;
    var by = 0.0;
    if (card.bottom > bottom) by = card.bottom - bottom;
    if (card.top - by < top) by = card.top - top; // taller than the gap: its top wins
    if (by.abs() < 1) return;
    const move = Duration(milliseconds: 250);
    if (_full) {
      final p = scroll.position;
      final to = (p.pixels + by).clamp(p.minScrollExtent, p.maxScrollExtent);
      if ((to - p.pixels).abs() >= 1) scroll.animateTo(to, duration: move, curve: Curves.easeOut);
    } else {
      _shift.animateTo(math.max(0.0, _shift.value + by), duration: move, curve: Curves.easeOut);
    }
  }

  void _revealTarget() {
    final t = _target;
    if (t != null && t.mounted) _reveal(t);
  }

  @override
  void initState() {
    super.initState();
    // A move the app makes (animateTo) sends no notification from the
    // sheet: follow the controller too, so the map's buttons keep up.
    _sheet.addListener(() {
      void sync() {
        if (mounted && _sheet.isAttached && (_sheet.size - _extent.value).abs() > 0.0001) _extent.value = _sheet.size;
      }

      // The sheet also reports while it rebuilds (a new min/max): wait for
      // the frame to finish then.
      SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks
          ? WidgetsBinding.instance.addPostFrameCallback((_) => sync())
          : sync();
    });
  }

  /// 0 shown, 1 slid out of sight ([MapSheetLayout.hidden]).
  late final _hide = AnimationController(
    vsync: this,
    duration: MapSheetLayout.hideDuration,
    value: widget.hidden ? 1 : 0,
  );

  /// How far down the sheet may be pulled (inDrive's): nearly all of it,
  /// leaving just the handle showing.
  double get _pullLimit {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !_sheet.isAttached) return 120;
    return math.max(120.0, box.size.height * _sheet.size - 28);
  }

  /// The pull curve: it follows the finger closely at first and gives less
  /// the nearer it gets to [_pullLimit], so the sheet can be pulled almost
  /// out of sight and then springs back up.
  static double _rubber(double pull, {double limit = 120}) =>
      pull <= 0 ? 0 : limit * (1 - math.exp(-1.2 * pull / limit));

  bool _onScroll(ScrollNotification n) {
    if (widget.locked) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      // Pulled down past fully down.
      _pull -= n.overscroll;
      _bounce.stop();
      _bounce.value = _rubber(_pull, limit: _pullLimit);
    } else if (n is ScrollEndNotification) {
      _springBack();
      // Let go at a new height: the chosen vehicle back in view.
      if (_moved) {
        _moved = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_full) _foldShift();
          _revealTarget();
        });
      }
    }
    return false;
  }

  void _springBack() {
    if (_pull == 0 && _bounce.value == 0) return;
    _pull = 0;
    _bounce.animateWith(
      SpringSimulation(const SpringDescription(mass: 1, stiffness: 500, damping: 32), _bounce.value, 0, 0),
    );
  }

  @override
  void didUpdateWidget(covariant MapSheetLayout old) {
    super.didUpdateWidget(old);
    // The sheet doesn't report a size it is clamped to, only one it is
    // dragged to: tell the map's buttons.
    if (widget.locked && !old.locked) _extent.value = widget.min;
    // A new resting height (the home sheet rising for the confirm step, or
    // settling back): the sheet moves to it.
    if ((widget.initial != old.initial || widget.min != old.min) && !widget.locked) {
      final to = widget.initial.clamp(widget.min, widget.max);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_sheet.isAttached) return;
        _sheet
            .animateTo(to, duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
            .then((_) => _revealTarget());
      });
    }
    if (widget.hidden != old.hidden) {
      widget.hidden ? _hide.animateTo(1, curve: Curves.easeIn) : _hide.animateBack(0, curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _bounce.dispose();
    _shift.dispose();
    _hide.dispose();
    _sheet.dispose();
    _extent.dispose();
    super.dispose();
  }

  /// A mouse wheel or trackpad over a sheet that is not fully up moves the
  /// sheet, as a drag would, instead of scrolling its content; so does
  /// scrolling back up past the top of the content of a full sheet. Inside
  /// the scroll view, so it is offered the event before the content is.
  Widget _wheelMovesSheet(Widget child, ScrollController scroll, double height) => Listener(
    onPointerSignal: (e) {
      if (e is! PointerScrollEvent || widget.locked || !_sheet.isAttached || height <= 0) return;
      final full = _sheet.size >= widget.max - 0.001;
      final scrolled = scroll.hasClients && scroll.offset > 0;
      if (full && (e.scrollDelta.dy > 0 || scrolled)) return; // the content's to scroll
      GestureBinding.instance.pointerSignalResolver.register(e, (event) {
        final dy = (event as PointerScrollEvent).scrollDelta.dy;
        _sheet.jumpTo((_sheet.size + dy / height).clamp(widget.min, widget.max));
      });
    },
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        return Stack(
          children: [
            Positioned.fill(
              child: MapBottomInset(
                extent: _extent,
                height: h,
                cap: h * (1 - widget.mapMinFraction),
                pull: _bounce,
                child: widget.map,
              ),
            ),
            AnimatedBuilder(
              animation: Listenable.merge([_hide, _extent]),
              // Always wrapped, so showing it again doesn't rebuild the sheet.
              builder: (_, child) => IgnorePointer(
                ignoring: _hide.value > 0,
                child: Transform.translate(
                  // Its own height and its shadow below the screen's edge.
                  offset: Offset(0, _hide.value * (h * _extent.value + 24)),
                  child: child,
                ),
              ),
              child: NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                // Dragged back up out of the rubber band: it springs home.
                if (n.extent > n.minExtent + 0.001) _springBack();
                if ((n.extent - _extent.value).abs() > 0.001) _moved = true;
                _extent.value = n.extent;
                return false;
              },
              child: DraggableScrollableSheet(
                key: const ValueKey('map-sheet'),
                controller: _sheet,
                initialChildSize: widget.locked ? widget.min : widget.initial,
                minChildSize: widget.min,
                maxChildSize: widget.locked ? widget.min : widget.max,
                builder: (context, scroll) {
                  _scroll = scroll;
                  return NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: AnimatedBuilder(
                    animation: _bounce,
                    builder: (_, child) => Transform.translate(offset: Offset(0, _bounce.value), child: child),
                    child: Material(
                      elevation: 8,
                      color: t.colorScheme.surface,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                      clipBehavior: Clip.antiAlias,
                      // The handle is pinned to the sheet's top edge: it stays in
                      // view while the content scrolls under it, and dragging it
                      // moves the sheet.
                      child: CustomScrollView(
                        controller: scroll,
                        // Content scrolls only in a sheet that is fully up: a drag
                        // moves the sheet first, and a sheet that is all the way
                        // down doesn't rubber-band its content when pulled (no
                        // iOS bounce). Held down, it neither moves nor scrolls.
                        physics: widget.locked ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
                        slivers: [
                          PinnedHeaderSliver(
                            child: ColoredBox(
                              key: const ValueKey('map-sheet-header'),
                              color: t.colorScheme.surface,
                              child: SizedBox(
                                height: 22,
                                child: Center(
                                  child: Container(
                                    key: const ValueKey('map-sheet-handle'),
                                    width: 40,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: t.colorScheme.outlineVariant,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (widget.peek != null) SliverToBoxAdapter(child: _wheelMovesSheet(widget.peek!, scroll, h)),
                          SliverToBoxAdapter(
                            child: AnimatedBuilder(
                              animation: _shift,
                              builder: (_, child) => _shift.value == 0
                                  ? child!
                                  : Transform.translate(offset: Offset(0, -_shift.value), child: child),
                              child: _wheelMovesSheet(
                              widget.peek == null
                                  ? widget.sheet
                                  : ValueListenableBuilder<double>(
                                      valueListenable: _extent,
                                      builder: (_, extent, child) {
                                        // Hidden all the way down; in as it rises.
                                        final shown = ((extent - widget.min) / 0.04).clamp(0.0, 1.0);
                                        return IgnorePointer(
                                          ignoring: shown < 1,
                                          child: Opacity(
                                            key: const ValueKey('map-sheet-body'),
                                            opacity: shown,
                                            child: child,
                                          ),
                                        );
                                      },
                                      child: widget.sheet,
                                    ),
                              scroll,
                              h,
                            ),
                            ),
                          ),
                          if (widget.footer != null) SliverToBoxAdapter(child: SizedBox(height: _footerHeight + _aboveHeight)),
                        ],
                      ),
                    ),
                  ),
                );
                },
              ),
            ),
            ),
            if (widget.footer != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _SizeReporter(
                  onSize: (size) {
                    if (!mounted || (size.height - _footerHeight).abs() <= 0.5) return;
                    setState(() => _footerHeight = size.height);
                    // A taller footer may now cover the chosen item.
                    WidgetsBinding.instance.addPostFrameCallback((_) => _revealTarget());
                  },
                  // Pulled down past its lowest, the footer goes with the
                  // sheet, and comes back up with it.
                  child: AnimatedBuilder(
                    animation: _bounce,
                    builder: (_, child) =>
                        _bounce.value == 0 ? child! : Transform.translate(offset: Offset(0, _bounce.value), child: child),
                    child: widget.footer!,
                  ),
                ),
              ),
            if (widget.aboveFooter != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: _footerHeight,
                child: _SizeReporter(
                  onSize: (size) {
                    if (mounted && (size.height - _aboveHeight).abs() > 0.5) setState(() => _aboveHeight = size.height);
                  },
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_hide, _extent]),
                    builder: (_, child) {
                      final up = _hide.value == 0 && _extent.value >= widget.max - MapSheetLayout.upSlack;
                      return IgnorePointer(
                        ignoring: !up,
                        child: AnimatedOpacity(
                          key: const ValueKey('map-sheet-above-footer'),
                          opacity: up ? 1 : 0,
                          duration: MapSheetLayout.fadeDuration,
                          child: child,
                        ),
                      );
                    },
                    child: widget.aboveFooter,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Tells [onSize] its child's size after each layout that changes it.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      final s = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onSize(s));
    }
  }
}

/// Keeps [child] whole in view on a [MapSheetLayout]'s sheet while [active]
/// (the confirm screen's chosen vehicle): scrolled above the pinned footer
/// when it is chosen, and again whenever the sheet is dragged to a new
/// height. Nothing outside a [MapSheetLayout].
class MapSheetReveal extends StatefulWidget {
  const MapSheetReveal({super.key, this.active = true, required this.child});

  final bool active;
  final Widget child;

  @override
  State<MapSheetReveal> createState() => _MapSheetRevealState();
}

class _MapSheetRevealState extends State<MapSheetReveal> {
  _MapSheetLayoutState? _layout;

  @override
  void initState() {
    super.initState();
    if (widget.active) _claim();
  }

  @override
  void didUpdateWidget(covariant MapSheetReveal old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _claim();
    if (!widget.active && old.active) _release();
  }

  void _claim() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    _layout = context.findAncestorStateOfType<_MapSheetLayoutState>();
    _layout?._target = context;
    _layout?._reveal(context);
  });

  void _release() {
    final layout = _layout;
    if (layout != null && layout._target == context) {
      layout._target = null;
      // Nothing to keep in view: the content back where it belongs, unless
      // another item is taking over (it slides it on from here).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (layout.mounted && layout._target == null) {
          layout._shift.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });
    }
    _layout = null;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
