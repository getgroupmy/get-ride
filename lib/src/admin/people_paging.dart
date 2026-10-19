// The admin people lists read `profiles` a page at a time (PERF-55): what a
// list has asked for so far, and the bar pinned under it with "Load more".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_filters.dart';

/// How many rows a paged list has asked for, and the search it sends to the
/// server (rows that aren't loaded yet are still found).
typedef PageRequest = ({int limit, String query});

class PageRequestController extends Notifier<PageRequest> {
  /// [pageSize] rows a page ([adminPeoplePageSizeFor] the list's width).
  PageRequestController([this.pageSize = adminPeoplePageSize]);

  final int pageSize;

  @override
  PageRequest build() => (limit: pageSize, query: '');

  /// One more page of the same search.
  void more() => state = (limit: state.limit + pageSize, query: state.query);

  /// A new search starts again from the first page.
  void search(String query) {
    final q = query.trim();
    if (q != state.query) state = (limit: pageSize, query: q);
  }
}

/// Pinned under a paged list while the server has more: the count and
/// "Load more", in reach without scrolling to the end of the list.
class PagedListBar extends StatelessWidget {
  const PagedListBar({super.key, required this.count, required this.loading, required this.onLoadMore});

  final String count;
  final bool loading;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      key: const ValueKey('paged-bar'),
      color: t.colorScheme.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
          child: Row(children: [
            Expanded(
              child: Text(count, key: const ValueKey('paged-count'), style: t.textTheme.bodyMedium),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('load-more'),
              onPressed: loading ? null : onLoadMore,
              icon: loading
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.expand_more),
              label: const Text('Load more'),
            ),
          ]),
        ),
      ),
    );
  }
}
