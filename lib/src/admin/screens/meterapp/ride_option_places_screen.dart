// Admin → Display Settings → Ride Options → Charges and where offered
// (migration 0253): pick a place (Default, or a country, state, city or
// suburb), then set its charges, switch an option off there or block it on
// some vehicle services. A place with nothing of its own uses the nearest
// place above it; with nothing set anywhere a charge is free. Names, order,
// show / hide and the two charge switches stay one setting for every place.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config.dart' show AppConfig;
import '../../../core/format.dart' show formatMoney;
import '../../../core/option_charge.dart';
import '../../../core/partner_type_rules.dart' show RegionScope;
import '../../../core/freight.dart' show FreightPlaceKey, isFreightValues;
import '../../../core/ride_option_places.dart';
import '../../../core/ride_option_settings.dart';
import '../../../core/trip_charges.dart' show parseChargeAmount;
import '../../../data/live_tables.dart';
import '../../../data/ride_option_places_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry, regionCurrency;
import 'display_logic.dart';
import 'display_screen.dart' show applyDisplay, displayPage;
import 'display_store.dart';

/// Every place's row, as the admin edits them.
final adminOptionPlacesProvider = FutureProvider.autoDispose<OptionPlaces>((ref) async {
  ref.watchLive(rideOptionPlacesTable);
  return OptionPlaces(await ref.watch(rideOptionPlacesRepositoryProvider).all() ?? const []);
});

/// The vehicle services an option can be blocked on: (id, name), in the
/// admin's order.
List<({String id, String name})> vehicleServicesOf(List<Map<String, dynamic>> rows) => [
  for (final r in rows)
    if (r['id'] is String)
      (id: r['id'] as String, name: '${(r['values'] as Map?)?['name'] ?? 'Unnamed'}'.trim()),
];

/// The freight sizes among [rows] (Vehicle Services under Freight, 0267):
/// what a freight option can be blocked on.
List<({String id, String name})> freightServicesOf(List<Map<String, dynamic>> rows) => vehicleServicesOf([
  for (final r in rows)
    if (r['values'] is Map && isFreightValues(Map<String, dynamic>.from(r['values'] as Map))) r,
]);

/// The places to pick from: Default, every region the admin has, and any
/// place with settings whose region has since gone.
List<RegionScope> optionPlaceChoices(List<RegionEntry> regions, OptionPlaces places) {
  final out = <String, RegionScope>{'': RegionScope.all};
  for (final r in regions) {
    final s = RegionScope(country: r.country, state: r.state, city: r.city, suburb: r.suburb);
    if (s.path.isNotEmpty) out.putIfAbsent(s.key, () => s);
  }
  for (final r in places.rows) {
    out.putIfAbsent(r.scope.key, () => r.scope);
  }
  final list = out.values.toList()
    ..sort((a, b) => a.path.join('\u0000').toLowerCase().compareTo(b.path.join('\u0000').toLowerCase()));
  return list;
}

class RideOptionPlacesScreen extends ConsumerStatefulWidget {
  const RideOptionPlacesScreen({super.key, this.initial = RegionScope.all});

  final RegionScope initial;

  @override
  ConsumerState<RideOptionPlacesScreen> createState() => _RideOptionPlacesScreenState();
}

class _RideOptionPlacesScreenState extends ConsumerState<RideOptionPlacesScreen> {
  late RegionScope _place = widget.initial;

  Future<void> _edit(OptionPlaceSettings Function(OptionPlaceSettings) f) async {
    final place = _place;
    await runAdminAction(context, () => ref.read(rideOptionPlacesRepositoryProvider).edit(place, f));
    ref.invalidate(adminOptionPlacesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final placesValue = ref.watch(adminOptionPlacesProvider);
    final settingsValue = ref.watch(displaySettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Charges and where offered')),
      body: AsyncView(
        value: settingsValue,
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (settings) => AsyncView(
          value: placesValue,
          onRetry: () => ref.invalidate(adminOptionPlacesProvider),
          data: (places) => _body(context, settings, places, canEdit),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> settings, OptionPlaces places, bool canEdit) {
    final config = rideOptionsOf(settings);
    final pets = petConfigOf(settings);
    final help = assistanceOf(settings);
    final rules = OptionChargeRules.fromSettings(settings);
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final serviceRows = ref.watch(settingsEntriesProvider('vehicle-services')).value ?? const <Map<String, dynamic>>[];
    final services = vehicleServicesOf(serviceRows);
    final freightServices = freightServicesOf(serviceRows);
    final place = _place;
    final parent = place.parent;
    final currency = place.isDefault ? AppConfig.currency : (regionCurrency(regions, place.country) ?? AppConfig.currency);
    String money(double v) => formatMoney(v, currency, v == v.roundToDouble() ? 0 : 2);
    final slots = optionChargeSlots(config, pets, help);
    final t = Theme.of(context);
    final muted = mutedTextColor(t, background: cardSurfaceColor(t));

    Future<void> pickPlace() async {
      final choices = optionPlaceChoices(regions, places);
      final picked = await showSearchPicker<RegionScope>(
        context,
        title: 'Charges for',
        selected: place,
        choices: [
          for (final c in choices)
            (
              value: c,
              label: c.placeName,
              subtitle: c.isDefault ? 'Every place without its own' : c.label,
              leading: places.at(c).isEmpty ? null : const Icon(Icons.edit_location_alt_outlined, size: 20),
            ),
        ],
      );
      if (picked != null && mounted) setState(() => _place = picked);
    }

    Widget fromBadge(RegionScope? from, {required bool own}) => own
        ? const _Pill(_PillKind.own, 'Set here')
        : from == null
            ? const _Pill(_PillKind.inherit, 'Nothing set')
            : _Pill(_PillKind.inherit, 'From ${from.placeName}');

    Widget useParent(String key, VoidCallback onPressed) => TextButton(
          key: ValueKey(key),
          onPressed: canEdit ? onPressed : null,
          child: Text("Use ${parent!.placeName}'s"),
        );

    Widget optionCard(RideOptionKind k) {
      final name = config.labelOf(k);
      final row = places.at(place);
      final offered = places.offeredAt(place, k);
      final ownOffered = row.offered.containsKey(k);
      final blocked = places.blockedAt(place, k);
      final ownBlocked = row.blocked.containsKey(k);
      final on = offered.value;
      final mySlots = [for (final s in slots) if (s.option == k) s];
      // A freight option is booked on the freight sizes only.
      final blockable = k.freight ? freightServices : services;
      return Card(
        key: ValueKey('place-option-${k.id}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
              Text(name, style: t.textTheme.titleMedium),
              if (ownOffered)
                const _Pill(_PillKind.own, 'Set here')
              else if (offered.from != null && !place.isDefault)
                _Pill(_PillKind.inherit, 'From ${offered.from!.placeName}'),
              if (!config.isShown(k)) const _Pill(_PillKind.off, 'Hidden everywhere'),
            ]),
            Row(children: [
              Expanded(child: Text('Offered here', style: t.textTheme.bodyMedium)),
              if (ownOffered && parent != null)
                useParent('place-offered-reset-${k.id}', () => _edit((r) => r.withOffered(k, null))),
              BusySwitch(
                key: ValueKey('place-offered-${k.id}'),
                value: on,
                onChanged: canEdit ? (v) => _edit((r) => r.withOffered(k, v)) : null,
              ),
            ]),
            if (!on)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                  const _Pill(_PillKind.off, 'Off'),
                  Text("Riders in ${place.placeName} don't see $name.", style: t.textTheme.bodySmall?.copyWith(color: muted)),
                ]),
              )
            else ...[
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
                Text('Services:', style: t.textTheme.bodySmall?.copyWith(color: muted)),
                if (blockable.isEmpty)
                  Text(
                    'No Freight vehicle services yet',
                    key: ValueKey('place-services-none-${k.id}'),
                    style: t.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                for (final s in blockable)
                  _ServiceChip(
                    key: ValueKey('place-service-${k.id}-${s.id}'),
                    name: s.name,
                    blocked: blocked.value.contains(s.id),
                    onTap: canEdit
                        ? () => _edit((r) {
                              final next = {...blocked.value};
                              next.contains(s.id) ? next.remove(s.id) : next.add(s.id);
                              return r.withBlocked(k, next);
                            })
                        : null,
                  ),
                if (ownBlocked) const _Pill(_PillKind.own, 'Set here')
                else if (blocked.from != null && !place.isDefault) _Pill(_PillKind.inherit, 'From ${blocked.from!.placeName}'),
                if (ownBlocked && parent != null)
                  useParent('place-blocked-reset-${k.id}', () => _edit((r) => r.withBlocked(k, null))),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(
                  "Tap a service to block or allow $name on it. Riders booking a blocked service don't see the option.",
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
            for (final s in mySlots)
              Opacity(
                opacity: on ? 1 : 0.5,
                child: _chargeLine(context, places, s, money, currency, canEdit, fromBadge, useParent),
              ),
          ]),
        ),
      );
    }

    return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
      ResponsiveCenter(
        maxWidth: 820,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            key: const ValueKey('option-place-bar'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: t.colorScheme.primary),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('Charges for', style: t.textTheme.titleMedium)),
                  Flexible(
                    child: OutlinedButton.icon(
                      key: const ValueKey('option-place-pick'),
                      onPressed: pickPlace,
                      icon: const Icon(Icons.place_outlined),
                      label: Text(place.placeName, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  for (final (i, c) in place.chain.reversed.indexed) ...[
                    if (i > 0) Icon(Icons.chevron_right, size: 16, color: muted),
                    ChoiceChip(
                      key: ValueKey('option-place-crumb-${c.key}'),
                      label: Text(c.placeName),
                      selected: c.key == place.key,
                      onSelected: (_) => setState(() => _place = c),
                    ),
                  ],
                ]),
                const SizedBox(height: 6),
                Text(
                  place.isDefault
                      ? "The amounts every place uses until it has its own. Each country's riders pay them in its own "
                          'currency.'
                      : 'Amounts in $currency. Anything not set here uses ${parent!.placeName}.',
                  key: const ValueKey('option-place-note'),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ]),
            ),
          ),
          Card(
            key: const ValueKey('option-place-global'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('Same everywhere', style: t.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                child: Text(
                  'Names, order, show / hide, Comments (always shown) and these two switches are one setting for '
                  'every place.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              BusySwitchListTile(
                key: const ValueKey('places-commission'),
                title: const Text('Commission applies to option charges'),
                value: rules.commission,
                onChanged: canEdit
                    ? (v) => applyDisplay(context, ref, (x) => setOptionChargeRules(x, commission: v))
                    : null,
              ),
              BusySwitchListTile(
                key: const ValueKey('places-promo'),
                title: const Text('Promo codes discount option charges'),
                value: rules.promo,
                onChanged:
                    canEdit ? (v) => applyDisplay(context, ref, (x) => setOptionChargeRules(x, promo: v)) : null,
              ),
            ]),
          ),
          for (final k in config.order)
            if (!k.freight) optionCard(k),
          // The Freight page's options (0267): a fixed charge each.
          Padding(
            key: const ValueKey('place-freight-heading'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Freight', style: t.textTheme.titleMedium),
              Text(
                'Helpers, closed body and riding along on the Freight page. Each charge is added to the rider\'s '
                'offer.',
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ]),
          ),
          for (final k in config.order)
            if (k.freight) optionCard(k),
          _freightValues(context, places, money, canEdit, fromBadge, useParent),
          _SummaryCard(
            places: places,
            place: place,
            config: config,
            slots: slots,
            services: services,
            money: money,
          ),
          const SizedBox(height: 32),
        ]),
      ),
    ]);
  }

  /// Waiting time, the cancel fee and the declared value cap here (0267).
  Widget _freightValues(
    BuildContext context,
    OptionPlaces places,
    String Function(double) money,
    bool canEdit,
    Widget Function(RegionScope?, {required bool own}) fromBadge,
    Widget Function(String, VoidCallback) useParent,
  ) {
    final t = Theme.of(context);
    final place = _place;
    final row = places.at(place);
    const labels = {
      FreightPlaceKey.waitFreeMin: 'Free waiting time',
      FreightPlaceKey.waitPerMin: 'Waiting fee a minute after it',
      FreightPlaceKey.cancelArrived: 'Fee when the sender cancels after the driver arrived',
      FreightPlaceKey.declaredCap: 'Most value a sender may declare',
    };
    String shown(String key, double v) => key == FreightPlaceKey.waitFreeMin ? '${trimNumber(v)} min' : money(v);
    return Card(
      key: const ValueKey('place-freight-values'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Freight waiting, cancelling and value', style: t.textTheme.titleMedium),
          Text(
            'The waiting fee is added to the fare when the trip starts; the cancel fee goes on the sender\'s next '
            'request and to the driver who waited.',
            style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t, background: cardSurfaceColor(t))),
          ),
          for (final key in FreightPlaceKey.all)
            () {
              final c = places.chargeAt(place, key);
              final own = row.charges.containsKey(key);
              final v = c.from == null ? FreightPlaceKey.fallback(key) : c.value.charge.value;
              Future<void> set() async {
                final n = await showAppDialog<double>(id: 'display.freight-place-value',
                  context: context,
                  builder: (_) => _FreightValueDialog(
                    title: '${labels[key]} · ${place.placeName}',
                    initial: v,
                    max: FreightPlaceKey.max(key),
                    suffix: key == FreightPlaceKey.waitFreeMin ? 'min' : null,
                  ),
                );
                if (n != null && mounted) {
                  await _edit((x) => x.withCharge(key, PlaceCharge(OptionCharge(value: n))));
                }
              }

              return Container(
                key: ValueKey('place-freight-$key'),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: t.dividerColor))),
                child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 140),
                    child: Text(labels[key]!, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  ),
                  fromBadge(c.from, own: own),
                  TextButton(
                    key: ValueKey('place-freight-edit-$key'),
                    onPressed: canEdit ? set : null,
                    child: Text(shown(key, v), key: ValueKey('place-freight-value-$key')),
                  ),
                  if (own && place.parent != null)
                    useParent('place-freight-reset-$key', () => _edit((x) => x.withCharge(key, null))),
                ]),
              );
            }(),
        ]),
      ),
    );
  }

  Widget _chargeLine(
    BuildContext context,
    OptionPlaces places,
    OptionChargeSlot s,
    String Function(double) money,
    String currency,
    bool canEdit,
    Widget Function(RegionScope?, {required bool own}) fromBadge,
    Widget Function(String, VoidCallback) useParent,
  ) {
    final t = Theme.of(context);
    final place = _place;
    final row = places.at(place);
    final own = row.charges.containsKey(s.key);
    final r = places.chargeAt(place, s.key);
    Future<void> setCharge() async {
      final c = await showAppDialog<PlaceCharge>(
        id: 'display.place-charge',
        context: context,
        builder: (_) => PlaceChargeDialog(
          title: '${s.label} · ${place.placeName}',
          initial: r.value,
          currency: currency,
          perPetChoice: s.perPetChoice,
          fixedOnly: s.fixedOnly,
        ),
      );
      if (c != null && mounted) await _edit((x) => x.withCharge(s.key, c));
    }

    return Container(
      key: ValueKey('place-charge-${s.key}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.dividerColor))),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 140),
          child: Text(s.label, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
        ),
        fromBadge(r.from, own: own),
        if (own) ...[
          TextButton(
            key: ValueKey('place-charge-edit-${s.key}'),
            onPressed: canEdit ? setCharge : null,
            child: Text(describePlaceCharge(r.value, money), key: ValueKey('place-charge-value-${s.key}')),
          ),
          if (_place.parent != null)
            useParent('place-charge-reset-${s.key}', () => _edit((x) => x.withCharge(s.key, null)))
          else
            TextButton(
              key: ValueKey('place-charge-clear-${s.key}'),
              onPressed: canEdit ? () => _edit((x) => x.withCharge(s.key, null)) : null,
              child: const Text('Clear'),
            ),
        ] else ...[
          Text(describePlaceCharge(r.value, money), key: ValueKey('place-charge-value-${s.key}')),
          TextButton(
            key: ValueKey('place-charge-set-${s.key}'),
            onPressed: canEdit ? setCharge : null,
            child: Text('Set for ${place.placeName}'),
          ),
        ],
      ]),
    );
  }
}

/// "What riders pay here" and "Offered by service here".
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.places,
    required this.place,
    required this.config,
    required this.slots,
    required this.services,
    required this.money,
  });

  final OptionPlaces places;
  final RegionScope place;
  final RideOptionsConfig config;
  final List<OptionChargeSlot> slots;
  final List<({String id, String name})> services;
  final String Function(double) money;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t, background: cardSurfaceColor(t));
    TableRow head(List<String> cells) => TableRow(children: [
          for (final c in cells)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              child: Text(c, style: t.textTheme.labelMedium?.copyWith(color: muted)),
            ),
        ]);
    Widget cell(Widget w) => Padding(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6), child: w);
    Widget table(List<TableRow> rows) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(horizontalInside: BorderSide(color: t.dividerColor)),
            children: rows,
          ),
        );
    return Card(
      key: const ValueKey('option-place-summary'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('What riders pay here', style: t.textTheme.titleMedium),
          Text('For the place picked above, each charge and where it comes from.',
              style: t.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 6),
          table([
            head(['Charge', 'Rider pays', 'Comes from']),
            for (final s in slots)
              () {
                final on = places.offeredAt(place, s.option).value;
                final r = places.chargeAt(place, s.key);
                return TableRow(key: ValueKey('summary-${s.key}'), children: [
                  cell(Text('${config.labelOf(s.option)} · ${s.label}')),
                  cell(Text(on ? describePlaceCharge(r.value, money) : '—', key: ValueKey('summary-pays-${s.key}'))),
                  cell(Text(
                    !on
                        ? '${config.labelOf(s.option)} is off here'
                        : r.from == null
                            ? 'Nothing set, so free'
                            : r.from!.key == place.key
                                ? 'Set here'
                                : r.from!.placeName,
                    key: ValueKey('summary-from-${s.key}'),
                  )),
                ]);
              }(),
          ]),
          const SizedBox(height: 16),
          Text('Offered by service here', style: t.textTheme.titleMedium),
          const SizedBox(height: 6),
          if (services.isEmpty)
            Text('No vehicle services yet.', style: t.textTheme.bodySmall?.copyWith(color: muted))
          else
            table([
              head(['Option', for (final s in services) s.name]),
              for (final k in config.order)
                TableRow(key: ValueKey('summary-service-${k.id}'), children: [
                  cell(Text(config.labelOf(k))),
                  for (final s in services)
                    cell(places.availableAt(place, k, serviceId: s.id) && config.isShown(k)
                        ? _Pill(_PillKind.own, 'Offered', key: ValueKey('summary-service-${k.id}-${s.id}'))
                        : _Pill(_PillKind.off, 'Blocked', key: ValueKey('summary-service-${k.id}-${s.id}'))),
                ]),
            ]),
        ]),
      ),
    );
  }
}

enum _PillKind { own, inherit, off }

/// "Set here", "From Selangor", "Nothing set", "Off": a small rounded tag
/// in the theme's container colours (light and dark).
class _Pill extends StatelessWidget {
  const _Pill(this.kind, this.text, {super.key});

  final _PillKind kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (bg, fg) = switch (kind) {
      _PillKind.own => (c.primaryContainer, c.onPrimaryContainer),
      _PillKind.inherit => (c.secondaryContainer, c.onSecondaryContainer),
      _PillKind.off => (c.errorContainer, c.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
    );
  }
}

/// A vehicle service an option is offered on (ticked) or blocked on
/// (struck through).
class _ServiceChip extends StatelessWidget {
  const _ServiceChip({super.key, required this.name, required this.blocked, this.onTap});

  final String name;
  final bool blocked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      label: '$name: ${blocked ? 'blocked' : 'offered'}',
      excludeSemantics: true,
      button: onTap != null,
      onTap: onTap,
      child: FilterChip(
        label: Text(name, style: blocked ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
        selected: !blocked,
        showCheckmark: true,
        selectedColor: c.primaryContainer,
        backgroundColor: c.errorContainer,
        onSelected: onTap == null ? null : (_) => onTap!(),
      ),
    );
  }
}

/// A charge for one place: a fixed amount or a percentage of the fare, per
/// pet or once per ride for a pet type. Empty or 0 is free here. Null when
/// cancelled.
class PlaceChargeDialog extends StatefulWidget {
  const PlaceChargeDialog({
    super.key,
    required this.title,
    required this.initial,
    required this.currency,
    this.perPetChoice = false,
    this.fixedOnly = false,
  });

  final String title;
  final PlaceCharge initial;
  final String currency;
  final bool perPetChoice;
  final bool fixedOnly;

  @override
  State<PlaceChargeDialog> createState() => _PlaceChargeDialogState();
}

class _PlaceChargeDialogState extends State<PlaceChargeDialog> {
  late final _amount = TextEditingController(
    text: widget.initial.charge.isZero ? '' : trimNumber(widget.initial.charge.value),
  );
  late OptionChargeKind _kind = widget.fixedOnly ? OptionChargeKind.fixed : widget.initial.charge.kind;
  late bool _perPet = widget.initial.perPet ?? true;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _save() {
    final text = _amount.text.trim();
    final n = text.isEmpty ? 0.0 : parseChargeAmount(text);
    if (n == null) return setState(() => _error = 'Enter the charge as a number, e.g. 5.');
    if (_kind == OptionChargeKind.percent && n > OptionCharge.maxPercent) {
      return setState(() => _error = 'A percentage is at most 100%.');
    }
    if (n > OptionCharge.maxAmount) {
      return setState(() => _error = 'A charge is at most ${OptionCharge.maxAmount.toStringAsFixed(0)}.');
    }
    Navigator.pop(
      context,
      PlaceCharge(OptionCharge(kind: _kind, value: n), perPet: widget.perPetChoice ? _perPet : null),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!widget.fixedOnly) ...[
                SegmentedButton<OptionChargeKind>(
                  key: const ValueKey('place-charge-kind'),
                  segments: const [
                    ButtonSegment(value: OptionChargeKind.fixed, label: Text('Fixed amount')),
                    ButtonSegment(value: OptionChargeKind.percent, label: Text('% of the fare')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (v) => setState(() => _kind = v.first),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                key: const ValueKey('place-charge-amount'),
                controller: _amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: _kind == OptionChargeKind.percent ? 'Charge (%)' : 'Charge (${widget.currency})',
                  helperText: 'Empty or 0: free here',
                  errorText: _error,
                ),
                onSubmitted: (_) => _save(),
              ),
              if (widget.perPetChoice) ...[
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  key: const ValueKey('place-charge-per'),
                  segments: const [
                    ButtonSegment(value: true, label: Text('Per pet')),
                    ButtonSegment(value: false, label: Text('Once per ride')),
                  ],
                  selected: {_perPet},
                  onSelectionChanged: (v) => setState(() => _perPet = v.first),
                ),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('place-charge-save'), onPressed: _save, child: const Text('Save')),
        ],
      );
}

/// One Freight value of a place: a number from 0 to [max].
class _FreightValueDialog extends StatefulWidget {
  const _FreightValueDialog({required this.title, required this.initial, required this.max, this.suffix});
  final String title;
  final double initial;
  final double max;
  final String? suffix;

  @override
  State<_FreightValueDialog> createState() => _FreightValueDialogState();
}

class _FreightValueDialogState extends State<_FreightValueDialog> {
  late final _text = TextEditingController(text: trimNumber(widget.initial));
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final n = double.tryParse(_text.text.trim());
    if (n == null || n < 0 || n > widget.max) {
      return setState(() => _problem = 'Enter a number from 0 to ${trimNumber(widget.max)}.');
    }
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('freight-place-value-field'),
      controller: _text,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(suffixText: widget.suffix, errorText: _problem),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(key: const ValueKey('freight-place-value-save'), onPressed: _save, child: const Text('Save')),
    ],
  );
}
