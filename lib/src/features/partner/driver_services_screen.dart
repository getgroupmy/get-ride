// The driver's Services page (side menu > Services; migration 0263): what
// the car they drive can do, with a switch for each service, the two street
// hail modes and the ride add-ons. Choices are kept per car and apply
// straight away. Services the car, its permits or the partner type can't
// take are greyed out with the reason; ones get.ride keeps on or off show a
// padlock and can't be changed here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/driver_services.dart';
import '../../core/format.dart' show formatDateForUser;
import '../../core/ride_extras.dart';
import '../../core/vehicle_assignment.dart';
import '../../data/driver_extras_repository.dart';
import '../../core/premium_plus.dart' show PremiumStatus;
import '../../data/driver_services_repository.dart';
import '../../data/premium_plus_repository.dart' show myPremiumStatusProvider;
import '../../data/ride_option_providers.dart';
import '../../data/ride_pet_repository.dart' show petConfigProvider;
import '../../data/vehicle_assignment_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../ride/hire_parts.dart' show TakeHourlyHireTile;
import 'vehicle_picker.dart';

const driverServicesPath = '/drive/services';

class DriverServicesScreen extends ConsumerStatefulWidget {
  const DriverServicesScreen({super.key});

  @override
  ConsumerState<DriverServicesScreen> createState() => _DriverServicesScreenState();
}

class _DriverServicesScreenState extends ConsumerState<DriverServicesScreen> {
  ServiceTab? _tab;

  /// Switches flipped and not yet read back, by key.
  final _pending = <String, bool>{};
  bool _changingCar = false;

  Future<void> _changeCar() async {
    List<AssignableVehicle> list;
    try {
      list = await ref.read(assignableVehiclesProvider.future);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final picked = await showAppSheet<AssignableVehicle>(
      id: 'driver-services.change-car',
      context: context,
      isScrollControlled: true,
      builder: (_) => VehiclePickerSheet(vehicles: list),
    );
    if (picked == null || picked.inUseByMe || !mounted) return;
    setState(() => _changingCar = true);
    try {
      await ref.read(vehicleAssignmentRepositoryProvider).claim(picked.id);
    } catch (e) {
      if (mounted) showInfo(context, claimVehicleErrorMessage(e));
    } finally {
      ref.invalidate(assignableVehiclesProvider);
      ref.invalidate(myDriverServicesProvider);
      if (mounted) {
        setState(() {
          _changingCar = false;
          _pending.clear();
        });
      }
    }
  }

  Future<void> _flip(DriverCar car, ServiceRow row, bool on, Set<String> extrasOff) async {
    setState(() => _pending[row.key] = on);
    try {
      final extra = DriverServiceKey.extraOf(row.key);
      if (extra != null) {
        // The add-ons are the driver's own list (0253), for every car.
        await ref.read(driverExtrasRepositoryProvider).setMine(on ? ({...extrasOff}..remove(extra)) : {...extrasOff, extra});
        ref.invalidate(myExtrasOffProvider);
      } else {
        await ref.read(driverServicesRepositoryProvider).setSwitch(car.id, row.key, on);
      }
      if (mounted) showInfo(context, serviceToggleToast(row.title, on));
    } catch (e) {
      if (mounted) {
        setState(() => _pending.remove(row.key));
        showError(context, e);
      }
      return;
    }
    ref.invalidate(myDriverServicesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(myDriverServicesProvider);
    // A fresh read replaces what was flipped here.
    ref.listen(myDriverServicesProvider, (_, next) {
      if (next.hasValue && !next.isLoading && _pending.isNotEmpty) setState(_pending.clear);
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Services')),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(myDriverServicesProvider),
        data: (o) => o.car == null ? _NoCar(onPick: _changeCar) : _body(context, o),
      ),
    );
  }

  Widget _body(BuildContext context, DriverServicesOverview o) {
    final t = Theme.of(context);
    final car = o.car!;
    final tab = _tab ?? firstTab(o);
    final extrasOff = ref.watch(myExtrasOffProvider).value ?? const <String>{};
    final addOns = rideExtraGroups(
      ref.watch(rideOptionsConfigProvider),
      ref.watch(petConfigProvider),
      ref.watch(assistanceCatalogueProvider),
    );
    final sections = servicesPageSections(
      o,
      tab,
      addOns: addOns,
      extrasOff: extrasOff,
      regionOff: ref.watch(driverServicesRegionOffProvider).value ?? const {},
    );
    return ListView(
      key: const ValueKey('driver-services'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        ResponsiveCenter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CarCard(car: car, details: o.carDetails, busy: _changingCar, onChange: _changeCar),
              const SizedBox(height: 12),
              // Premium services and whether this driver qualifies (0316).
              if (tab != ServiceTab.deliveries)
                for (final p in ref.watch(myPremiumStatusProvider).value ?? const <PremiumStatus>[])
                  Padding(padding: const EdgeInsets.only(bottom: 12), child: PremiumStatusCard(status: p)),
              SegmentedButton<ServiceTab>(
                key: const ValueKey('driver-services-tabs'),
                showSelectedIcon: false,
                segments: [
                  for (final x in ServiceTab.values)
                    ButtonSegment(value: x, label: Text(x.label, key: ValueKey('driver-services-tab-${x.name}'))),
                ],
                selected: {tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              // Hourly hire (0326): off until the driver turns it on.
              if (tab != ServiceTab.deliveries) const TakeHourlyHireTile(),
              for (final s in sections) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
                  child: Text(s.title, style: t.textTheme.titleMedium),
                ),
                if (s.hint != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                    child: Text(s.hint!, style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
                  ),
                if (s.rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                    child: Text(
                      tab == ServiceTab.deliveries ? 'No delivery services for this car.' : 'No ride services for this car.',
                      style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
                    ),
                  )
                else
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < s.rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _ServiceTile(
                            row: s.rows[i],
                            on: _pending[s.rows[i].key] ?? s.rows[i].shownOn,
                            onChanged: (v) => _flip(car, s.rows[i], v, extrasOff),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Text(servicesFooter, style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A Premium service (0316): "You can take Premium requests", or why not.
class PremiumStatusCard extends StatelessWidget {
  const PremiumStatusCard({super.key, required this.status});
  final PremiumStatus status;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ok = status.ok;
    return Card(
      key: ValueKey('premium-status-${status.service}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? Icons.verified_outlined : Icons.diamond_outlined,
              color: ok ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                ok ? 'You can take ${status.service} requests' : 'You don\'t qualify for ${status.service} yet',
                style: t.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              if (ok)
                Text(
                  status.rulesOn
                      ? 'Your car, rating and trips meet the ${status.service} rules here.'
                      : 'No ${status.service} rules apply here.',
                  style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                )
              else
                for (final r in status.reasons)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('• $r', style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
                  ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The car in use, with Change car.
class _CarCard extends StatelessWidget {
  const _CarCard({required this.car, required this.details, required this.busy, required this.onChange});
  final DriverCar car;
  final String details;
  final bool busy;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('driver-services-car'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            if (car.plate.isNotEmpty) PlateChip(plate: car.plate),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(car.title, style: t.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (details.isNotEmpty)
                    Text(
                      details,
                      style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : TextButton(
                    key: const ValueKey('driver-services-change-car'),
                    onPressed: onChange,
                    child: const Text('Change car'),
                  ),
          ],
        ),
      ),
    );
  }
}

/// A number plate: dark characters on a light plate, in both themes.
class PlateChip extends StatelessWidget {
  const PlateChip({super.key, required this.plate});
  final String plate;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: Colors.black87, width: 1.5),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      plate,
      style: const TextStyle(
        color: Colors.black,
        fontWeight: FontWeight.w700,
        fontSize: 13,
        fontFamily: 'monospace',
        letterSpacing: 0.5,
      ),
    ),
  );
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.row, required this.on, required this.onChanged});
  final ServiceRow row;
  final bool on;
  final ValueChanged<bool> onChanged;

  IconData get _icon => switch (row.kind) {
    ServiceRowKind.service => Icons.directions_car_outlined,
    ServiceRowKind.hail => Icons.hail_outlined,
    ServiceRowKind.addOn => Icons.add_circle_outline,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = mutedTextColor(t, background: t.cardTheme.color ?? cs.surfaceContainerLow);
    final greyed = row.reason != null;
    final lock = row.lock;
    final Widget body = Row(
      children: [
        Opacity(
          opacity: greyed ? 0.45 : 1,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(12)),
            child: Icon(_icon, color: cs.onPrimaryContainer),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Opacity(
                opacity: greyed ? 0.45 : 1,
                child: Text(row.title, style: t.textTheme.titleSmall),
              ),
              if (row.subtitle.isNotEmpty)
                Text(row.subtitle, style: t.textTheme.bodySmall?.copyWith(color: muted)),
              if (greyed)
                _Badge(
                  key: ValueKey('driver-service-reason-${row.key}'),
                  text: row.reason!,
                  background: cs.tertiaryContainer,
                  foreground: cs.onTertiaryContainer,
                ),
              if (lock != null)
                _Badge(
                  key: ValueKey('driver-service-lock-${row.key}'),
                  icon: Icons.lock_outline,
                  text: lock.until == null
                      ? lockLabel(lock)
                      : '${lockLabel(lock)} until ${formatDateForUser(lock.until!.toLocal())}',
                  background: cs.secondaryContainer,
                  foreground: cs.onSecondaryContainer,
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          key: ValueKey('driver-service-switch-${row.key}'),
          value: lock != null ? lock.on : on,
          onChanged: row.switchable ? onChanged : null,
        ),
      ],
    );
    final padded = Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: body);
    return Semantics(
      label: row.title,
      child: lock != null
          ? InkWell(
              key: ValueKey('driver-service-row-${row.key}'),
              onTap: () => showInfo(context, lockedServiceMessage),
              child: padded,
            )
          : KeyedSubtree(key: ValueKey('driver-service-row-${row.key}'), child: padded),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.text, required this.background, required this.foreground, this.icon});
  final String text;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: foreground), const SizedBox(width: 4)],
          Flexible(child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground))),
        ],
      ),
    ),
  );
}

/// No car in use: the page has nothing to show until one is taken.
class _NoCar extends StatelessWidget {
  const _NoCar({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_car_outlined, size: 48, color: mutedTextColor(t)),
            const SizedBox(height: 12),
            Text('Choose the car you are driving', style: t.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              'Services are kept for each car. Choose one to see what it can take.',
              style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(key: const ValueKey('driver-services-pick-car'), onPressed: onPick, child: const Text('Choose a car')),
            TextButton(onPressed: () => context.push('/drive/vehicles'), child: const Text('My vehicles')),
          ],
        ),
      ),
    );
  }
}
