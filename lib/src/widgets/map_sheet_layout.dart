import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
    required super.child,
  });

  /// The sheet's size, as a fraction of [height].
  final ValueListenable<double> extent;
  final double height;

  /// The most the inset grows to: a sheet dragged higher simply covers the
  /// buttons, rather than pushing them off the top of the map.
  final double cap;

  double get value => (height * extent.value).clamp(0.0, cap);

  /// [build] with the current inset, rebuilt as the sheet moves.
  static Widget listen(BuildContext context, Widget Function(double inset) build) {
    final m = context.dependOnInheritedWidgetOfExactType<MapBottomInset>();
    if (m == null) return build(0);
    return ValueListenableBuilder<double>(valueListenable: m.extent, builder: (_, _, _) => build(m.value));
  }

  /// The inset right now (for a one-off camera fit).
  static double of(BuildContext context) => context.getInheritedWidgetOfExactType<MapBottomInset>()?.value ?? 0;

  @override
  bool updateShouldNotify(MapBottomInset old) => old.extent != extent || old.height != height || old.cap != cap;
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

  @override
  State<MapSheetLayout> createState() => _MapSheetLayoutState();
}

class _MapSheetLayoutState extends State<MapSheetLayout> {
  late final _extent = ValueNotifier<double>(widget.locked ? widget.min : widget.initial);

  @override
  void didUpdateWidget(covariant MapSheetLayout old) {
    super.didUpdateWidget(old);
    // The sheet doesn't report a size it is clamped to, only one it is
    // dragged to: tell the map's buttons.
    if (widget.locked && !old.locked) _extent.value = widget.min;
  }

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

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
                child: widget.map,
              ),
            ),
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                _extent.value = n.extent;
                return false;
              },
              child: DraggableScrollableSheet(
                key: const ValueKey('map-sheet'),
                initialChildSize: widget.locked ? widget.min : widget.initial,
                minChildSize: widget.min,
                maxChildSize: widget.locked ? widget.min : widget.max,
                builder: (context, scroll) => Material(
                  elevation: 8,
                  color: t.colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  clipBehavior: Clip.antiAlias,
                  // The handle is pinned to the sheet's top edge: it stays in
                  // view while the content scrolls under it, and dragging it
                  // moves the sheet.
                  child: CustomScrollView(
                    controller: scroll,
                    // Held down, it neither moves nor scrolls: content
                    // scrolls only in a sheet that is fully up.
                    physics: widget.locked ? const NeverScrollableScrollPhysics() : null,
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
                      if (widget.peek != null) SliverToBoxAdapter(child: widget.peek),
                      SliverToBoxAdapter(
                        child: widget.peek == null
                            ? widget.sheet
                            : ValueListenableBuilder<double>(
                                valueListenable: _extent,
                                builder: (_, extent, child) {
                                  // Hidden all the way down; in as it rises.
                                  final shown = ((extent - widget.min) / 0.04).clamp(0.0, 1.0);
                                  return IgnorePointer(
                                    ignoring: shown < 1,
                                    child: Opacity(opacity: shown, child: child),
                                  );
                                },
                                child: widget.sheet,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
