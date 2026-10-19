// The admin people lists read `profiles` a page at a time (PERF-55): what a
// list has asked for so far, and the "Load more" row at its end.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_filters.dart';

/// How many rows a paged list has asked for, and the search it sends to the
/// server (rows that aren't loaded yet are still found).
typedef PageRequest = ({int limit, String query});

class PageRequestController extends Notifier<PageRequest> {
  @override
  PageRequest build() => (limit: adminPeoplePageSize, query: '');

  /// One more page of the same search.
  void more() => state = (limit: state.limit + adminPeoplePageSize, query: state.query);

  /// A new search starts again from the first page.
  void search(String query) {
    final q = query.trim();
    if (q != state.query) state = (limit: adminPeoplePageSize, query: q);
  }
}

/// The last row of a paged list: "Load more" while the server has more.
class LoadMoreRow extends StatelessWidget {
  const LoadMoreRow({super.key, required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: OutlinedButton.icon(
            key: const ValueKey('load-more'),
            onPressed: loading ? null : onPressed,
            icon: loading
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.expand_more),
            label: const Text('Load more'),
          ),
        ),
      );
}
