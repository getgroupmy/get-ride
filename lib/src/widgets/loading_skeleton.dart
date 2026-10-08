import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

/// What the app shows while a page's data loads, in place of a spinner: a
/// shimmering outline of a list of rows ([Skeletonizer]), so the page has
/// its shape before its content lands. It shimmers in the app's own light
/// or dark theme rather than the platform's (Skeletonizer's default).
///
/// It fits wherever a spinner did: as many rows as the space allows when
/// the height is bounded, [rows] when it isn't (inside a list).
class LoadingSkeleton extends StatelessWidget {
  const LoadingSkeleton({super.key, this.rows = 6, this.leading = true});

  /// The most rows drawn.
  final int rows;

  /// Whether each row has a round leading avatar.
  final bool leading;

  /// The height one row takes up.
  static const rowHeight = 72.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final fit = c.maxHeight.isFinite ? (c.maxHeight / rowHeight).floor().clamp(1, rows) : rows;
      return ClipRect(
        child: SkeletonizerConfig(
          data: SkeletonizerConfigData(brightness: Theme.of(context).brightness),
          child: Skeletonizer(
            key: const ValueKey('loading-skeleton'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < fit; i++)
                  SizedBox(
                    height: rowHeight,
                    child: ListTile(
                      leading: leading ? const Bone.circle(size: 40) : null,
                      // Lengths vary row to row, as real content does.
                      title: Text(i.isEven ? 'A title for this row' : 'A longer title for this row here'),
                      subtitle: Text(i % 3 == 0 ? 'Some detail underneath' : 'Detail'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// A whole page loading: [LoadingSkeleton] from the top, under whatever
/// app bar the page has.
class LoadingSkeletonPage extends StatelessWidget {
  const LoadingSkeletonPage({super.key});

  @override
  Widget build(BuildContext context) => const Align(
    alignment: Alignment.topCenter,
    child: Padding(padding: EdgeInsets.only(top: 8), child: LoadingSkeleton()),
  );
}
