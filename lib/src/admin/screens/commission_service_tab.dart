// Admin → Commission → Per service (migration 0306): a Vehicle Service can
// have its own rate, used everywhere instead of the place rate. A driver's
// own rate still comes first; tiers and a lower running promotion still
// apply on top. A preview shows what a trip pays.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/city_to_city.dart' show commissionForService, CommissionSource, c2cMoney;
import '../../data/city_to_city_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';
import 'commission_screen.dart' show commissionRatesProvider, commissionScopeLabel;
import 'geo/geo_data.dart' show regionVehicleTypesProvider;
import 'geo/geo_logic.dart' show ServiceOption;
import 'city_to_city/c2c_widgets.dart' show C2cCardTitle;

/// The fare the preview charges.
const commissionPreviewFare = 100.0;

class CommissionServiceTab extends ConsumerStatefulWidget {
  const CommissionServiceTab({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<CommissionServiceTab> createState() => _CommissionServiceTabState();
}

class _CommissionServiceTabState extends ConsumerState<CommissionServiceTab> {
  /// Changes not saved yet: service id to its own rate (a fraction), or null
  /// for the place rate.
  final _draft = <String, double?>{};
  String? _selected;
  int _place = 0;

  double? _rateOf(String id, Map<String, double> stored) => _draft.containsKey(id) ? _draft[id] : stored[id];

  Future<void> _save(List<ServiceOption> services, Map<String, double> stored) async {
    final repo = ref.read(cityToCityRepositoryProvider);
    final names = {for (final s in services) s.id: s.name};
    final changes = {
      for (final e in _draft.entries)
        if (e.value != stored[e.key]) e.key: e.value,
    };
    final ok = await runAdminAction(context, () async {
      for (final e in changes.entries) {
        await repo.setServiceRate(e.key, names[e.key] ?? e.key, e.value);
      }
    }, success: 'Service rates saved');
    if (ok && mounted) {
      setState(_draft.clear);
      ref.invalidate(commissionServiceRatesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(regionVehicleTypesProvider);
    final rates = ref.watch(commissionServiceRatesProvider);
    final t = Theme.of(context);
    return AsyncView(
      value: rates,
      onRetry: () => ref.invalidate(commissionServiceRatesProvider),
      data: (stored) {
        final list = services.value ?? const <ServiceOption>[];
        final selected = list.where((s) => s.id == _selected).firstOrNull ?? list.firstOrNull;
        final changed = _draft.entries.any((e) => e.value != stored[e.key]);
        final rows = Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const C2cCardTitle(Icons.layers_outlined, 'Commission per service'),
              Text(
                'A service with its own rate uses it everywhere, instead of the city, state or country rate. Leave '
                'it on Place rate to keep today\'s behaviour. Tap a service to preview it.',
                style: t.textTheme.bodySmall,
              ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No vehicle services yet.'),
                ),
              ListSearchFilter(
                count: list.length,
                hint: 'Search services',
                fieldKey: const ValueKey('commission-service-search'),
                builder: (context, q) => Column(children: [
                  for (final s in list)
                    if (q.isEmpty || s.name.toLowerCase().contains(q.toLowerCase()))
                      _ServiceRow(
                        service: s,
                        rate: _rateOf(s.id, stored),
                        selected: s.id == selected?.id,
                        canEdit: widget.canEdit,
                        onSelect: () => setState(() => _selected = s.id),
                        onRate: (v) => setState(() => _draft[s.id] = v),
                      ),
                ]),
              ),
              if (widget.canEdit)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      key: const ValueKey('commission-service-save'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed: changed ? () => _save(list, stored) : null,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ),
                ),
            ]),
          ),
        );
        final places = [
          for (final r in ref.watch(commissionRatesProvider).value ?? const <Map<String, dynamic>>[])
            if (r['level'] != 'user' && r['active'] != false && r['rate'] is num)
              (label: commissionScopeLabel(r), rate: (r['rate'] as num).toDouble()),
        ];
        final preview = selected == null
            ? const SizedBox.shrink()
            : _Preview(
                service: selected,
                ownRate: _rateOf(selected.id, stored),
                places: places,
                place: places.isEmpty ? 0 : _place.clamp(0, places.length - 1),
                onPlace: (i) => setState(() => _place = i),
              );
        return LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 900;
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: rows),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: Column(children: [preview, const _WhichWins()])),
              ])
            else ...[rows, preview, const _WhichWins()],
          ]);
        });
      },
    );
  }
}

String _pct(double fraction) {
  final v = fraction * 100;
  return '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}%';
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.service,
    required this.rate,
    required this.selected,
    required this.canEdit,
    required this.onSelect,
    required this.onRate,
  });

  final ServiceOption service;
  final double? rate;
  final bool selected, canEdit;
  final VoidCallback onSelect;
  final ValueChanged<double?> onRate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final own = rate != null;
    return Material(
      color: selected ? t.colorScheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('commission-service-${service.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              SizedBox(
                width: 180,
                child: Row(children: [
                  Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 20, color: selected ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(child: Text(service.name, style: t.textTheme.bodyLarge)),
                ]),
              ),
              SegmentedButton<bool>(
                key: ValueKey('commission-service-mode-${service.id}'),
                style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Place rate')),
                  ButtonSegment(value: true, label: Text('Own rate')),
                ],
                selected: {own},
                onSelectionChanged: canEdit ? (v) => onRate(v.first ? (rate ?? 0.12) : null) : null,
              ),
              if (own)
                SizedBox(
                  width: 200,
                  child: Row(children: [
                    IconButton(
                      tooltip: 'Lower ${service.name} rate',
                      icon: const Icon(Icons.remove),
                      onPressed: canEdit && rate! >= 0.005 ? () => onRate(((rate! - 0.005) * 1000).round() / 1000) : null,
                    ),
                    Expanded(
                      child: Text(_pct(rate!),
                          key: ValueKey('commission-service-rate-${service.id}'),
                          textAlign: TextAlign.center,
                          style: t.textTheme.titleMedium),
                    ),
                    IconButton(
                      tooltip: 'Raise ${service.name} rate',
                      icon: const Icon(Icons.add),
                      onPressed: canEdit && rate! <= 0.395 ? () => onRate(((rate! + 0.005) * 1000).round() / 1000) : null,
                    ),
                  ]),
                )
              else
                Text('Follows the place', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.service,
    required this.ownRate,
    required this.places,
    required this.place,
    required this.onPlace,
  });

  final ServiceOption service;
  final double? ownRate;
  final List<({String label, double rate})> places;
  final int place;
  final ValueChanged<int> onPlace;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = places.isEmpty ? (label: 'Built-in default', rate: 0.15) : places[place];
    final r = commissionForService(serviceRate: ownRate, placeRate: p.rate);
    final comm = commissionPreviewFare * r.rate;
    Widget line(String a, String b, {bool strong = false, Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(a)),
        Text(b, key: key, style: strong ? t.textTheme.titleSmall : null),
      ]),
    );
    return Card(
      key: const ValueKey('commission-service-preview'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.calculate_outlined, 'Preview'),
          Text('${service.name}: a trip picked up in', style: t.textTheme.bodyMedium),
          const SizedBox(height: 6),
          ListSearchFilter(
            count: places.length,
            hint: 'Search places',
            fieldKey: const ValueKey('commission-service-place-search'),
            builder: (context, q) => Wrap(spacing: 6, runSpacing: 6, children: [
              for (var i = 0; i < places.length; i++)
                if (q.isEmpty || places[i].label.toLowerCase().contains(q.toLowerCase()))
                  ChoiceChip(
                    key: ValueKey('commission-service-place-$i'),
                    label: Text('${places[i].label} ${_pct(places[i].rate)}'),
                    selected: i == place,
                    onSelected: (_) => onPlace(i),
                  ),
            ]),
          ),
          const SizedBox(height: 8),
          line('Fare', c2cMoney(commissionPreviewFare)),
          line('Rate used', _pct(r.rate), key: const ValueKey('commission-service-used')),
          line('GET.ride commission', c2cMoney(comm)),
          line('Driver gets', c2cMoney(commissionPreviewFare - comm), strong: true),
          const SizedBox(height: 6),
          Text(
            r.source == CommissionSource.service
                ? '${service.name} has its own ${_pct(r.rate)}, so the ${p.label} rate of ${_pct(p.rate)} is not used.'
                : 'No own rate for ${service.name}, so the ${p.label} rate of ${_pct(p.rate)} applies.',
            key: const ValueKey('commission-service-why'),
            style: t.textTheme.bodySmall?.copyWith(
              color: r.source == CommissionSource.service ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
            ),
          ),
        ]),
      ),
    );
  }
}

class _WhichWins extends StatelessWidget {
  const _WhichWins();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const steps = [
      'The driver\'s own rate (per user)',
      'A running promotion, when it is lower',
      'The service\'s own rate',
      'The place rate: suburb, then city, then state, then country',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.format_list_numbered, 'Which rate wins (first match)'),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${i + 1}. ${steps[i]}', key: ValueKey('commission-service-step-$i')),
            ),
          const SizedBox(height: 6),
          Text(
            'Tiers lower a service rate as they lower a place rate; a driver\'s own rate is never lowered. The rate '
            'is locked when the driver accepts the trip.',
            style: t.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

