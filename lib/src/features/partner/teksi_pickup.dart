// Start Pickup on the TEKSI permit screen (Expo `partner-teksi.tsx`): the
// permit's checks (IC, expiry, and the vehicle — with a re-pick until it
// matches), "Select tariff", the destination, the "Trip summary" and the
// "Confirm your trip" page, then the meter with the hire running. The meter
// bills what it measures; every figure before it is an estimate, and says so.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../admin/screens/meterapp/meter_logic.dart';
import '../../core/driver_permit.dart';
import '../../core/street_hail.dart';
import '../../core/teksi_tariff.dart';
import '../../core/vehicle_assignment.dart';
import '../../data/geo_service.dart';
import '../../data/vehicle_assignment_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../meter/hail_destination_screen.dart';
import '../meter/meter_providers.dart';
import '../meter/meter_screen.dart' show MeterLaunch;
import 'driver_permit_screen.dart';
import 'vehicle_picker.dart';

/// Where the driver is now; a provider so tests can place them.
final teksiPositionProvider = Provider<Future<LatLng?> Function()>((_) => currentPosition);

/// Today, for the permit's expiry; a provider so tests can fix the date.
final teksiTodayProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// The whole Start Pickup flow, from the permit screen.
Future<void> startTeksiPickup(BuildContext context, WidgetRef ref) async {
  if (!await teksiPermitCleared(context, ref) || !context.mounted) return;
  final tariff = await showTariffPicker(context);
  if (tariff == null || !context.mounted) return;
  await planTeksiTrip(context, ref, tariff);
}

/// Expo `attemptStartPickup`: IC and expiry first, then the vehicle, which
/// the driver may re-pick until it matches the permit. True to carry on;
/// when the permit cannot be read the driver is let through, as elsewhere.
Future<bool> teksiPermitCleared(BuildContext context, WidgetRef ref) async {
  final DriverPermit permit;
  try {
    ref.invalidate(assignableVehiclesProvider);
    permit = await ref.read(driverPermitProvider.future);
  } catch (_) {
    return true;
  }
  var again = false;
  while (context.mounted) {
    final plate = await _currentPlate(ref);
    final block = permitStartBlock(permit, today: ref.read(teksiTodayProvider)(), vehiclePlate: plate);
    if (block == null) return true;
    if (!context.mounted) return false;
    if (block != PermitBlock.plateMismatch) {
      await showPermitBlock(context, block, permit, plate);
      return false;
    }
    final pick = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('teksi-plate-mismatch'),
        title: Text(again ? "Still doesn't match" : 'Vehicle mismatch'),
        content: Text(
          again
              ? 'The vehicle you picked ($plate) is not the one on your permit (${permit.vehiclePlate}).'
              : 'The selected vehicle does not match your permit.\n\n'
                    'Permit vehicle: ${permit.vehiclePlate}\nSelected vehicle: $plate\n\n'
                    'Please select the vehicle that matches your permit.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('teksi-select-vehicle'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(c, true),
            child: Text(again ? 'Choose another' : 'Select vehicle'),
          ),
        ],
      ),
    );
    if (pick != true || !context.mounted) return false;
    if (!await _pickVehicle(context, ref)) return false;
    again = true;
  }
  return false;
}

Future<String?> _currentPlate(WidgetRef ref) async {
  try {
    final list = await ref.read(assignableVehiclesProvider.future);
    return list.where((v) => v.inUseByMe).firstOrNull?.plate;
  } catch (_) {
    return null;
  }
}

/// The vehicle picker; true once the driver holds the vehicle picked.
Future<bool> _pickVehicle(BuildContext context, WidgetRef ref) async {
  List<AssignableVehicle> list;
  try {
    list = await ref.read(assignableVehiclesProvider.future);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  final picked = await showModalBottomSheet<AssignableVehicle>(
    context: context,
    isScrollControlled: true,
    builder: (_) => VehiclePickerSheet(vehicles: list),
  );
  if (picked == null || !context.mounted) return false;
  if (picked.inUseByMe) return true;
  try {
    await ref.read(vehicleAssignmentRepositoryProvider).claim(picked.id);
    ref.invalidate(assignableVehiclesProvider);
    return true;
  } catch (e) {
    if (context.mounted) showInfo(context, claimVehicleErrorMessage(e));
    return false;
  }
}

/// "Select tariff" (Expo): New or Old; null when dismissed.
Future<TeksiTariff?> showTariffPicker(BuildContext context) => showModalBottomSheet<TeksiTariff>(
  context: context,
  isScrollControlled: true,
  builder: (c) {
    final t = Theme.of(c);
    return SafeArea(
      child: Padding(
        key: const ValueKey('tariff-picker'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Select tariff', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
              'Choose the fare structure for this pickup.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (final tariff in TeksiTariff.values) ...[
              _TariffOption(tariff: tariff, onTap: () => Navigator.pop(c, tariff)),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  },
);

class _TariffOption extends StatelessWidget {
  const _TariffOption({required this.tariff, required this.onTap});
  final TeksiTariff tariff;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = t.colorScheme.primary;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('tariff-option-${tariff.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tariff.badge,
                  style: t.textTheme.labelMedium?.copyWith(color: accent, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tariff.title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    for (final l in tariff.lines) Text(l, style: t.textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    Text(tariff.blurb, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: t.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// The trip a TEKSI pickup is about to drive: where from, where to, the
/// route, and the fare it is quoted on.
class TeksiTripPlan {
  const TeksiTripPlan({
    required this.tariff,
    required this.card,
    required this.destination,
    required this.pickupName,
    this.pickupAddress,
    this.estimate,
  });

  final TeksiTariff tariff;
  final ResolvedMeterProfile card;
  final HailDestination destination;
  final String pickupName;
  final String? pickupAddress;
  final double? estimate;

  String get currency {
    final c = card.profile.currency.trim();
    return c.isEmpty || c.toUpperCase() == 'MYR' ? 'RM' : c;
  }

  String get fareText => estimate == null ? '—' : '$currency ${estimate!.ceil()}';
  String get headingTo => [
    destination.name,
    if (destination.address != null && destination.address != destination.name) destination.address!,
  ].join(', ');
  List<String> get tariffLines => tariffSummaryLines(card, tariff);
}

/// From the tariff on: the destination, the trip summary (Edit goes back to
/// the destination) and the confirm page, then the meter.
Future<void> planTeksiTrip(BuildContext context, WidgetRef ref, TeksiTariff tariff) async {
  final origin = await ref.read(teksiPositionProvider)();
  if (!context.mounted) return;
  final geo = ref.read(geoServiceProvider);
  // The card the meter will bill on here: an operator's card wins over the
  // tariff, as on the meter, so the quote matches the meter.
  AreaInfo? area;
  Place? here;
  List<MeterProfile> cards = const [];
  if (origin != null) {
    try {
      area = await geo.reverseArea(origin);
    } catch (_) {}
    try {
      here = await geo.reverse(origin);
    } catch (_) {}
  }
  try {
    cards = await ref.read(meterCardsProvider.future);
  } catch (_) {}
  if (!context.mounted) return;
  final card = resolveMeterProfile(
    cards,
    country: area?.country,
    state: area?.state,
    city: area?.city,
    suburb: area?.suburb,
  );
  final rates = ratesForTariff(card, tariff);
  final currency = card.profile.currency.trim().isEmpty || card.profile.currency.toUpperCase() == 'MYR'
      ? 'RM'
      : card.profile.currency.trim();
  HailDestination? dest;
  while (context.mounted) {
    dest = await context.push<HailDestination>(
      '/meter/destination',
      extra: HailDestinationArgs(origin: origin, rates: rates, currency: currency, current: dest),
    );
    if (dest == null || !context.mounted) return;
    final plan = TeksiTripPlan(
      tariff: tariff,
      card: card,
      destination: dest,
      pickupName: here?.name ?? 'Current location',
      pickupAddress: here?.address,
      estimate: hailEstimate(rates, dest),
    );
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => TeksiTripSummary(plan: plan),
    );
    if (go == null || !context.mounted) return;
    if (!go) continue; // Edit: back to the destination.
    final start = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => ConfirmTeksiTripScreen(plan: plan)));
    if (start != true || !context.mounted) return;
    context.push(
      '/meter',
      extra: MeterLaunch(tariff: tariff, destination: dest, startHire: true),
    );
    return;
  }
}

String _km(HailDestination d) => d.routeKm == null ? '—' : '${d.routeKm!.toStringAsFixed(1)} km';
String _min(HailDestination d) => d.routeMin == null ? '—' : '${d.routeMin!.round().clamp(1, 1 << 30)} min';

/// "Trip summary" (Expo): distance, duration and the estimated fare; Edit
/// pops false, Start driving true.
class TeksiTripSummary extends StatelessWidget {
  const TeksiTripSummary({super.key, required this.plan});
  final TeksiTripPlan plan;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = plan.destination;
    return AlertDialog(
      key: const ValueKey('trip-summary'),
      icon: Icon(Icons.check_circle, color: t.colorScheme.primary, size: 40),
      title: const Text('Trip summary'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Heading to ${plan.headingTo}',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _Stat(value: _km(d), label: 'Distance'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Stat(value: _min(d), label: 'Duration'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _FareCard(plan: plan),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('trip-summary-edit'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Edit'),
        ),
        FilledButton(
          key: const ValueKey('trip-summary-start'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Start driving'),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value, label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Text(value, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _FareCard extends StatelessWidget {
  const _FareCard({required this.plan, this.large = false});
  final TeksiTripPlan plan;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = t.colorScheme.onPrimaryContainer;
    return Container(
      key: const ValueKey('trip-fare'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: t.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Estimated fare', style: t.textTheme.labelLarge?.copyWith(color: on)),
          Text(
            plan.fareText,
            style: (large ? t.textTheme.displaySmall : t.textTheme.headlineMedium)?.copyWith(
              color: on,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          for (final l in plan.tariffLines) Text(l, style: t.textTheme.bodySmall?.copyWith(color: on)),
        ],
      ),
    );
  }
}

/// "Confirm your trip" (Expo, READY TO ROLL): the trip once more before the
/// meter starts. Pops true on Start.
class ConfirmTeksiTripScreen extends StatelessWidget {
  const ConfirmTeksiTripScreen({super.key, required this.plan});
  final TeksiTripPlan plan;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = plan.destination;
    final muted = t.colorScheme.onSurfaceVariant;
    Widget end(String label, String name, String? address, IconData icon) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: t.colorScheme.primary),
      title: Text(
        label,
        style: t.textTheme.labelMedium?.copyWith(color: muted, fontWeight: FontWeight.w700),
      ),
      subtitle: Text([name, if (address != null && address != name) address].join('\n'), style: t.textTheme.bodyLarge),
    );
    return Scaffold(
      key: const ValueKey('confirm-trip'),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, false),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                children: [
                  ResponsiveCenter(
                    maxWidth: 560,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'READY TO ROLL',
                          style: t.textTheme.labelLarge?.copyWith(
                            color: t.colorScheme.primary,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          'Confirm your trip',
                          style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text('Heading to ${plan.headingTo}', style: t.textTheme.bodyMedium?.copyWith(color: muted)),
                        const SizedBox(height: 16),
                        _FareCard(plan: plan, large: true),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _Stat(value: _km(d), label: 'Distance'),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _Stat(value: _min(d), label: 'Duration'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Column(
                              children: [
                                end('PICKUP', plan.pickupName, plan.pickupAddress, Icons.my_location),
                                const Divider(height: 1),
                                end('DROP-OFF', d.name, d.address, Icons.flag),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline, size: 18, color: muted),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Drive safely. Fare is an estimate; the meter bills the actual route and traffic.',
                                style: t.textTheme.bodySmall?.copyWith(color: muted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: ResponsiveCenter(
                maxWidth: 560,
                child: FilledButton.icon(
                  key: const ValueKey('confirm-trip-start'),
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
