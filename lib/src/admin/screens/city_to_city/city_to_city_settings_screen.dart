// Admin → Services & catalogue → City to City (migration 0306): the cancel
// fee, the payment methods, the minimum driving experience, the permits a
// driver needs per country, and where City to City is offered (the region
// service switches, 0302, on the Regions page).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/city_to_city.dart';
import '../../../data/city_to_city_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry, RegionLevel;
import 'c2c_widgets.dart';

const cityToCityPath = '/admin/m/city-to-city';
const cityToCityRoutesPath = '/admin/m/city-to-city-routes';
const _moneyPath = '/admin/m/city-to-city-money';
const _regionsPath = '/admin/m/country-states-cities';

class CityToCitySettingsScreen extends ConsumerStatefulWidget {
  const CityToCitySettingsScreen({super.key});

  @override
  ConsumerState<CityToCitySettingsScreen> createState() => _CityToCitySettingsScreenState();
}

class _CityToCitySettingsScreenState extends ConsumerState<CityToCitySettingsScreen> {
  C2cSettings? _draft;
  C2cSettings? _loaded;

  bool get _changed =>
      _draft != null && _loaded != null && _draft!.toRow().toString() != _loaded!.toRow().toString();

  Future<void> _save() async {
    final d = _draft;
    if (d == null) return;
    final why = d.problem;
    if (why != null) {
      showError(context, why);
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(cityToCityRepositoryProvider).saveSettings(d),
      success: 'City to City settings saved',
    );
    if (ok) {
      setState(() => _loaded = d);
      ref.invalidate(c2cSettingsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(c2cPage)) == AccessLevel.edit;
    final async = ref.watch(c2cSettingsProvider);
    return AdminPage(
      title: 'City to City',
      page: c2cPage,
      actions: [
        IconButton(
          key: const ValueKey('c2c-open-routes'),
          tooltip: 'Route rules and fares',
          icon: const Icon(Icons.route_outlined),
          onPressed: () => context.push(cityToCityRoutesPath),
        ),
      ],
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(c2cSettingsProvider),
        data: (stored) {
          if (_loaded == null || (!_changed && _loaded!.toRow().toString() != stored.toRow().toString())) {
            _loaded = stored;
            _draft = stored;
          }
          final s = _draft!;
          void set(C2cSettings v) => setState(() => _draft = v);
          final left = [
            _CancelCard(s: s, onChanged: canEdit ? set : null),
            _PaymentCard(s: s, onChanged: canEdit ? set : null),
            _YearsCard(s: s, onChanged: canEdit ? set : null),
          ];
          final right = [
            _PermitsCard(canEdit: canEdit),
            const _AvailabilityCard(),
          ];
          final save = canEdit
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        s.problem ?? (_changed ? 'Not saved yet.' : 'Saved.'),
                        key: const ValueKey('c2c-settings-state'),
                        style: TextStyle(
                          color: s.problem != null
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('c2c-settings-save'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed: _changed && s.problem == null ? _save : null,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ]),
                )
              : const SizedBox.shrink();
          return LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 900;
            final intro = Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'These apply to every City to City trip. The rider\'s check step and booking read the cancel '
                'rule from here.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    intro,
                    if (wide)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Column(children: left)),
                        const SizedBox(width: 16),
                        Expanded(child: Column(children: right)),
                      ])
                    else ...[...left, ...right],
                    save,
                  ]),
                ),
              ),
            );
          });
        },
      ),
    );
  }
}

class _CancelCard extends StatelessWidget {
  const _CancelCard({required this.s, this.onChanged});
  final C2cSettings s;
  final ValueChanged<C2cSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    final hours = s.cancelFreeHours;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.event_busy_outlined, 'Cancelling'),
          SwitchListTile(
            key: const ValueKey('c2c-fee-on'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Charge a cancel fee'),
            subtitle: const Text('Off: free to cancel any time'),
            value: s.cancelFeeOn,
            onChanged: on == null ? null : (v) => on(s.copyWith(cancelFeeOn: v)),
          ),
          if (s.cancelFeeOn) ...[
            C2cStepper(
              label: 'Fee',
              hint: 'Goes to the driver',
              value: c2cMoney(s.cancelFeeAmount, s.currency),
              valueKey: const ValueKey('c2c-fee'),
              onDown: on == null || s.cancelFeeAmount <= 5
                  ? null
                  : () => on(s.copyWith(cancelFeeAmount: s.cancelFeeAmount - 5)),
              onUp: on == null ? null : () => on(s.copyWith(cancelFeeAmount: s.cancelFeeAmount + 5)),
            ),
            C2cStepper(
              label: 'Free until',
              hint: 'Hours before pickup, default 24',
              value: '$hours h',
              valueKey: const ValueKey('c2c-hours'),
              onDown: on == null || hours <= 1
                  ? null
                  : () => on(s.copyWith(cancelFreeHours: hours - (hours > 12 ? 6 : 1))),
              onUp: on == null || hours >= 720
                  ? null
                  : () => on(s.copyWith(cancelFreeHours: hours + (hours >= 12 ? 6 : 1))),
            ),
          ],
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'Riders see: ', style: TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: s.cancelLine),
            ]),
            key: const ValueKey('c2c-cancel-line'),
          ),
        ]),
      ),
    );
  }
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({required this.s, this.onChanged});
  final C2cSettings s;
  final ValueChanged<C2cSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.payments_outlined, 'Payment methods'),
          CheckboxListTile(
            key: const ValueKey('c2c-pay-app'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('In app'),
            value: s.payInApp,
            onChanged: on == null ? null : (v) => on(s.copyWith(payInApp: v ?? false)),
          ),
          CheckboxListTile(
            key: const ValueKey('c2c-pay-cash'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Cash'),
            value: s.payCash,
            onChanged: on == null ? null : (v) => on(s.copyWith(payCash: v ?? false)),
          ),
          if (!s.payInApp && !s.payCash)
            Text(
              'Keep at least one method on.',
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w500),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('c2c-open-money'),
              onPressed: () => context.push(_moneyPath),
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: const Text('In-app payment, fees and reminders'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _YearsCard extends StatelessWidget {
  const _YearsCard({required this.s, this.onChanged});
  final C2cSettings s;
  final ValueChanged<C2cSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.badge_outlined, 'Driving experience'),
          SwitchListTile(
            key: const ValueKey('c2c-years-on'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Require minimum driving experience'),
            subtitle: const Text('Off: no restriction anywhere'),
            value: s.minYearsOn,
            onChanged: on == null ? null : (v) => on(s.copyWith(minYearsOn: v)),
          ),
          if (s.minYearsOn)
            C2cStepper(
              label: 'Minimum years driving',
              hint: 'Default for route rules; a rule can set its own',
              value: '${s.minYears} ${s.minYears == 1 ? 'year' : 'years'}',
              valueKey: const ValueKey('c2c-years'),
              onDown: on == null || s.minYears <= 1 ? null : () => on(s.copyWith(minYears: s.minYears - 1)),
              onUp: on == null || s.minYears >= 60 ? null : () => on(s.copyWith(minYears: s.minYears + 1)),
            ),
          Text(
            'Counted from when the driver\'s licence was first issued (their partner record), else their '
            'approved driving licence. A driver whose date is unknown doesn\'t meet a minimum.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

/// Permits per country: added and removed at once.
class _PermitsCard extends ConsumerWidget {
  const _PermitsCard({required this.canEdit});
  final bool canEdit;

  Future<void> _add(BuildContext context, WidgetRef ref, String country, List<C2cCountryPermit> have) async {
    final types = ref.read(c2cPermitTypesProvider).value ?? const <C2cPermitType>[];
    final taken = {for (final p in have) if (p.country == country) p.permitTypeId};
    final choices = [
      for (final t in types)
        if (!taken.contains(t.id))
          (
            value: t.id,
            label: t.name,
            subtitle: '${t.appliesTo == 'driver' ? 'Driver' : 'Vehicle'} permit · ${t.country}',
            leading: Icon(t.appliesTo == 'driver' ? Icons.badge_outlined : Icons.directions_car_outlined),
          ),
    ];
    if (choices.isEmpty) {
      showInfo(context, 'No more permit types to add. Add them under People, Vehicle permits first.');
      return;
    }
    final id = await showSearchPicker<String>(context, title: 'Permit needed in $country', choices: choices);
    if (id == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(cityToCityRepositoryProvider).addCountryPermit(country, id, position: have.length + 1),
    );
    if (ok) ref.invalidate(c2cCountryPermitsProvider);
  }

  Future<void> _addCountry(BuildContext context, WidgetRef ref, List<C2cCountryPermit> have) async {
    final regions = ref.read(regionsProvider).value ?? const <RegionEntry>[];
    final listed = {for (final p in have) p.country.toLowerCase()};
    final country = await showSearchPicker<String>(
      context,
      title: 'Add a country',
      choices: [
        for (final e in regions)
          if (e.level == RegionLevel.country && e.country.isNotEmpty && !listed.contains(e.country.toLowerCase()))
            (value: e.country, label: e.country, subtitle: null, leading: const Icon(Icons.public)),
      ],
    );
    if (country == null || !context.mounted) return;
    await _add(context, ref, country, have);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(c2cCountryPermitsProvider);
    // Read by Add permit and Add a country: kept loaded while the card shows.
    ref.watch(c2cPermitTypesProvider);
    ref.watch(regionsProvider);
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.verified_user_outlined, 'Permits needed by country'),
          Text(
            'Checked for the pickup country and each country the trip enters; a driver without them doesn\'t '
            'get those requests.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: async,
            onRetry: () => ref.invalidate(c2cCountryPermitsProvider),
            data: (permits) {
              final byCountry = <String, List<C2cCountryPermit>>{};
              for (final p in permits) {
                byCountry.putIfAbsent(p.country, () => []).add(p);
              }
              final countries = byCountry.keys.toList()..sort();
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (countries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No permits needed anywhere yet.', key: const ValueKey('c2c-permits-empty'),
                        style: t.textTheme.bodyMedium),
                  ),
                ListSearchFilter(
                  count: countries.length,
                  hint: 'Search countries',
                  fieldKey: const ValueKey('c2c-permits-search'),
                  builder: (context, q) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final c in countries)
                      if (q.isEmpty || c.toLowerCase().contains(q.toLowerCase()))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Row(children: [
                              const Icon(Icons.public, size: 20),
                              const SizedBox(width: 6),
                              Expanded(child: Text(c, style: t.textTheme.titleSmall)),
                              if (canEdit)
                                TextButton.icon(
                                  key: ValueKey('c2c-permit-add-$c'),
                                  onPressed: () => _add(context, ref, c, permits),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add permit'),
                                ),
                            ]),
                            Wrap(spacing: 6, runSpacing: 6, children: [
                              for (final p in byCountry[c]!)
                                InputChip(
                                  key: ValueKey('c2c-permit-${p.id}'),
                                  avatar: Icon(p.appliesTo == 'driver' ? Icons.badge_outlined : Icons.directions_car_outlined,
                                      size: 18),
                                  label: Text(p.label),
                                  deleteButtonTooltipMessage: 'Remove ${p.name}',
                                  onDeleted: !canEdit || p.id == null
                                      ? null
                                      : () async {
                                          if (await runAdminAction(context,
                                              () => ref.read(cityToCityRepositoryProvider).removeCountryPermit(p.id!))) {
                                            ref.invalidate(c2cCountryPermitsProvider);
                                          }
                                        },
                                ),
                            ]),
                          ]),
                        ),
                  ]),
                ),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('c2c-permit-country'),
                      onPressed: () => _addCountry(context, ref, permits),
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Add a country'),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  'Each permit is the driver\'s or the vehicle\'s, as its permit type says, with an expiry date the '
                  'driver uploads.',
                  style: t.textTheme.bodySmall,
                ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

/// Where City to City is offered: the region switches, on the Regions page.
class _AvailabilityCard extends ConsumerWidget {
  const _AvailabilityCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(c2cFareContextProvider).value?.service;
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.map_outlined, 'Where City to City is offered'),
          Text(
            'A rider can book only when the pickup is in a place where City to City is On. In Regions, open a '
            'country, state, city or suburb and set City to City under Services to Inherit, On or Off; Inherit '
            'follows the place above it. The server checks the pickup again when the trip is booked.',
            style: t.textTheme.bodyMedium,
          ),
          if (service != null && !service.active) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.info_outline, color: t.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  service.id == null
                      ? 'There is no City to City vehicle service yet.'
                      : 'The City to City vehicle service is off in Vehicle Services, so it is offered nowhere.',
                  key: const ValueKey('c2c-service-off'),
                  style: TextStyle(color: t.colorScheme.error),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              key: const ValueKey('c2c-open-regions'),
              onPressed: () => context.push(_regionsPath),
              icon: const Icon(Icons.public),
              label: const Text('Open Regions'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('c2c-open-routes-card'),
              onPressed: () => context.push(cityToCityRoutesPath),
              icon: const Icon(Icons.route_outlined),
              label: const Text('Route rules and fares'),
            ),
          ]),
        ]),
      ),
    );
  }
}
