// The request history list, for one side of the person (core/trip_history.dart):
// Trips on the user side, Drive → Trip history on the partner side. Chips
// filter by status; older requests load a page at a time.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/region_time.dart';
import '../../core/trip_history.dart';
import '../../data/models.dart';
import '../../data/trip_history_repository.dart';
import '../../widgets/common.dart';

class TripHistoryView extends ConsumerStatefulWidget {
  const TripHistoryView({super.key, required this.role});

  final TripHistoryRole role;

  @override
  ConsumerState<TripHistoryView> createState() => _TripHistoryViewState();
}

class _TripHistoryViewState extends ConsumerState<TripHistoryView> {
  var _filter = TripHistoryFilter.all;
  final _rows = <RideRequest>[];
  bool _loading = false;
  bool _more = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    _rows.clear();
    _more = true;
    await _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final filter = _filter;
    try {
      final page = await ref
          .read(tripHistoryRepositoryProvider)
          .page(widget.role, filter: filter, before: _rows.isEmpty ? null : _rows.last.createdAt);
      if (!mounted || filter != _filter) return;
      setState(() {
        _rows.addAll(page);
        _more = page.length >= tripHistoryPageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pick(TripHistoryFilter f) {
    if (f == _filter) return;
    setState(() => _filter = f);
    unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) {
    final partner = widget.role == TripHistoryRole.partner;
    final chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        spacing: 8,
        children: [
          for (final f in TripHistoryFilter.values)
            ChoiceChip(
              key: ValueKey('trip-filter-${f.name}'),
              label: Text(f.label),
              selected: f == _filter,
              onSelected: (_) => _pick(f),
            ),
        ],
      ),
    );
    final Widget body;
    if (_rows.isEmpty && _loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_rows.isEmpty && _error != null) {
      body = ListView(
        children: [
          EmptyState(
            icon: Icons.cloud_off_outlined,
            title: "Couldn't load your trips",
            message: errorText(_error!),
            action: OutlinedButton(onPressed: () => unawaited(_reload()), child: const Text('Try again')),
          ),
        ],
      );
    } else if (_rows.isEmpty) {
      body = ListView(
        children: [
          EmptyState(
            icon: partner ? Icons.drive_eta_outlined : Icons.receipt_long,
            title: _filter == TripHistoryFilter.all ? 'No trips yet' : 'No ${_filter.label.toLowerCase()} trips',
            message: partner ? 'Trips you drive will show up here.' : 'Rides you book will show up here.',
          ),
        ],
      );
    } else {
      body = ListView.builder(
        itemCount: _rows.length + 1,
        itemBuilder: (_, i) {
          if (i == _rows.length) {
            if (!_more) return const SizedBox(height: 24);
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : OutlinedButton(
                        key: const ValueKey('trip-history-more'),
                        onPressed: () => unawaited(_load()),
                        child: const Text('Load more'),
                      ),
              ),
            );
          }
          final r = _rows[i];
          return ResponsiveCenter(
            maxWidth: 760,
            child: Card(
              key: ValueKey('trip-${r.id}'),
              child: ListTile(
                leading: Icon(partner ? Icons.drive_eta : Icons.local_taxi),
                title: Text('${r.pickupLabel} → ${r.dropLabel}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${formatInZone(r.createdAt, r.timezone)} · ${r.status.label}'),
                trailing: Text(r.fareText(r.effectiveFare)),
                onTap: () => context.push(tripHistoryRoute(widget.role, r)),
              ),
            ),
          );
        },
      );
    }
    return Column(
      children: [
        chips,
        Expanded(
          child: RefreshIndicator(onRefresh: _reload, child: body),
        ),
      ],
    );
  }
}
