import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Every bottom sheet in the app: rounded top corners and a handle to drag
/// it by (down to close; the tall ones also up to expand).
const appBottomSheetTheme = BottomSheetThemeData(
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
  clipBehavior: Clip.antiAlias,
  showDragHandle: true,
);

/// A map with a draggable sheet over it (phone layout): the sheet has
/// rounded top corners and a handle, and is dragged up to expand rather
/// than scrolled inside a fixed panel. The map keeps to the space above the
/// sheet (up to [mapMinFraction] of the height), so its own buttons stay in
/// view whatever the sheet's size.
class MapSheetLayout extends StatefulWidget {
  const MapSheetLayout({
    super.key,
    required this.map,
    required this.sheet,
    this.initial = 0.45,
    this.min = 0.2,
    this.max = 0.92,
    this.mapMinFraction = 0.4,
  });

  final Widget map;
  final Widget sheet;
  final double initial, min, max;

  /// The least of the screen the map keeps when the sheet is dragged high.
  final double mapMinFraction;

  @override
  State<MapSheetLayout> createState() => _MapSheetLayoutState();
}

class _MapSheetLayoutState extends State<MapSheetLayout> {
  late final _extent = ValueNotifier<double>(widget.initial);

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
            ValueListenableBuilder<double>(
              valueListenable: _extent,
              builder: (_, extent, child) => Positioned(
                left: 0,
                right: 0,
                top: 0,
                // Up to the sheet's top edge (overlapping its rounded corners),
                // but never smaller than mapMinFraction of the screen.
                height: math.max(h * widget.mapMinFraction, h * (1 - extent) + 20),
                child: child!,
              ),
              child: widget.map,
            ),
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                _extent.value = n.extent;
                return false;
              },
              child: DraggableScrollableSheet(
                key: const ValueKey('map-sheet'),
                initialChildSize: widget.initial,
                minChildSize: widget.min,
                maxChildSize: widget.max,
                builder: (context, scroll) => Material(
                  elevation: 8,
                  color: t.colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    controller: scroll,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            key: const ValueKey('map-sheet-handle'),
                            width: 40,
                            height: 4,
                            margin: const EdgeInsets.only(top: 10, bottom: 2),
                            decoration: BoxDecoration(
                              color: t.colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        widget.sheet,
                      ],
                    ),
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
