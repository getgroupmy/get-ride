// The driver's request filters (migration 0311): minimum fare, maximum
// pickup distance and sort, within the admin's limits (Admin › Settings ›
// Ride safety). Saved on the phone and to the account. They only hide
// requests from the driver's own list.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/ride_safety.dart';
import '../../data/ride_safety_repository.dart';
import '../../widgets/page_style_host.dart';

/// The row on the driver's online card: "Filters on", what they do, and how
/// many requests they hide now.
class RequestFiltersTile extends ConsumerWidget {
  const RequestFiltersTile({super.key, this.hidden = 0});

  /// Requests hidden from the list right now.
  final int hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(rideSafetySettingsProvider).value ?? const RideSafetySettings();
    if (!settings.minFareOn && !settings.distanceOn && !settings.sortOn) return const SizedBox.shrink();
    final f = ref.watch(effectiveRequestFiltersProvider);
    return ListTile(
      key: const ValueKey('queue-filters'),
      leading: const Icon(Icons.tune),
      title: Text(f.active ? 'Filters on' : 'Request filters'),
      subtitle: Text([f.summary(settings.currency), if (hidden > 0) hiddenRequestsLine(hidden)].join('\n')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showRequestFilters(context),
    );
  }
}

Future<void> showRequestFilters(BuildContext context) => showAppSheet<void>(
      id: 'partner.request-filters',
      context: context,
      fitContent: true,
      builder: (_) => const RequestFiltersSheet(),
    );

/// "Filter requests": changed as the driver taps, saved when they close it
/// with Show requests.
class RequestFiltersSheet extends ConsumerStatefulWidget {
  const RequestFiltersSheet({super.key});

  @override
  ConsumerState<RequestFiltersSheet> createState() => _RequestFiltersSheetState();
}

class _RequestFiltersSheetState extends ConsumerState<RequestFiltersSheet> {
  late RequestFilters _f = ref.read(effectiveRequestFiltersProvider);

  String _km(double km) => km == km.roundToDouble() ? '${km.round()} km' : '${km.toStringAsFixed(1)} km';

  Future<void> _done() async {
    await ref.read(requestFiltersProvider.notifier).set(_f);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = ref.watch(rideSafetySettingsProvider).value ?? const RideSafetySettings();
    final cur = s.currency;
    final maxKm = _f.maxKm;
    Widget stepper({
      required String label,
      required String hint,
      required String value,
      required Key valueKey,
      required VoidCallback? onDown,
      required VoidCallback? onUp,
      required String downTip,
      required String upTip,
    }) =>
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
              Text(hint, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          IconButton.outlined(tooltip: downTip, icon: const Icon(Icons.remove), onPressed: onDown),
          SizedBox(
            width: 72,
            child: Text(value, key: valueKey, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
          ),
          IconButton.outlined(tooltip: upTip, icon: const Icon(Icons.add), onPressed: onUp),
        ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Filter requests', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (s.minFareOn) ...[
          stepper(
            label: 'Minimum fare',
            hint: 'Admin allows up to ${formatMoney(s.minFareCap, cur, 0)}',
            value: _f.minFare <= 0 ? 'Any' : formatMoney(_f.minFare, cur, 0),
            valueKey: const ValueKey('filter-min-fare'),
            downTip: 'Lower',
            upTip: 'Raise',
            onDown: _f.minFare <= 0
                ? null
                : () => setState(() => _f = _f.copyWith(minFare: (_f.minFare - requestFareStep).clamp(0, s.minFareCap).toDouble())),
            onUp: _f.minFare >= s.minFareCap
                ? null
                : () => setState(() => _f = _f.copyWith(minFare: (_f.minFare + requestFareStep).clamp(0, s.minFareCap).toDouble())),
          ),
          const SizedBox(height: 8),
        ],
        if (s.distanceOn) ...[
          stepper(
            label: 'Max pickup distance',
            hint: 'Admin allows ${_km(s.distanceMinKm)} to ${_km(s.distanceMaxKm)}',
            value: maxKm == null ? 'Any' : _km(maxKm),
            valueKey: const ValueKey('filter-max-km'),
            downTip: 'Closer',
            upTip: 'Further',
            onDown: maxKm != null && maxKm <= s.distanceMinKm
                ? null
                : () => setState(() => _f = _f.copyWith(
                      maxKm: maxKm == null
                          ? s.distanceMaxKm
                          : (maxKm - requestKmStep).clamp(s.distanceMinKm, s.distanceMaxKm).toDouble(),
                    )),
            // Past the admin's longest: any distance.
            onUp: maxKm == null
                ? null
                : () => setState(() => _f = maxKm >= s.distanceMaxKm
                    ? _f.copyWith(anyDistance: true)
                    : _f.copyWith(maxKm: (maxKm + requestKmStep).clamp(s.distanceMinKm, s.distanceMaxKm).toDouble())),
          ),
          const SizedBox(height: 8),
        ],
        if (s.sortOn) ...[
          Text('Sort by', style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          SegmentedButton<RequestSort>(
            key: const ValueKey('filter-sort'),
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            segments: [
              for (final o in RequestSort.values) ButtonSegment(value: o, label: Text(o.label)),
            ],
            selected: {_f.sort},
            onSelectionChanged: (v) => setState(() => _f = _f.copyWith(sort: v.first)),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          'Filters only hide requests from your list; your acceptance rate doesn\'t count hidden ones. '
          'Saved on this phone and your account.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              key: const ValueKey('filter-reset'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => setState(() => _f = RequestFilters.none),
              child: const Text('Reset'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: FilledButton(
              key: const ValueKey('filter-done'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _done,
              child: const Text('Show requests'),
            ),
          ),
        ]),
      ]),
    );
  }
}
