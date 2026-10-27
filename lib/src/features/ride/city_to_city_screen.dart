// City to City, the rider's page (migration 0307; the approved mockup's
// RiderHome card): what the service is, Plan a trip, and the rider's trips
// (waiting for offers, booked, done), each opening the trip screen. The home
// box "City to City" opens it once the Vehicle Service is switched on.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/city_to_city.dart';
import '../../data/city_to_city_repository.dart';
import '../../widgets/common.dart' show AsyncView;
import '../../widgets/page_style_host.dart';
import 'city_to_city_parts.dart';
import 'city_to_city_steps.dart' show openC2cSteps;
import 'city_to_city_trip.dart' show openC2cTrip;

/// Opens the City to City page.
Future<void> openCityToCityPage(BuildContext context) => Navigator.of(context)
    .push<void>(AppPageRoute(id: 'ride.city-to-city', builder: (_) => const CityToCityScreen()));

class CityToCityScreen extends ConsumerWidget {
  const CityToCityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final trips = ref.watch(c2cMyTripsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('City to City')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => ref.invalidate(c2cMyTripsProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              C2cBox(
                key: const ValueKey('c2c-hero'),
                color: look.hero,
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('City to City', style: t.textTheme.bodySmall?.copyWith(color: look.onHero)),
                  const SizedBox(height: 6),
                  Text('Going further? Book a whole car to another city, door to door.',
                      style: t.textTheme.titleLarge?.copyWith(color: look.onHero, height: 1.3)),
                  const SizedBox(height: 6),
                  Text('GET.ride shows the fare most drivers accept. You choose, drivers offer.',
                      style: t.textTheme.bodyMedium?.copyWith(color: look.onHero)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('c2c-plan'),
                    style: FilledButton.styleFrom(backgroundColor: look.onHero, foregroundColor: look.hero),
                    onPressed: () => openC2cSteps(context),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Plan a trip'),
                  ),
                ]),
              ),
              const SizedBox(height: 18),
              Text('Your trips', style: t.textTheme.titleMedium),
              const SizedBox(height: 8),
              AsyncView<List<C2cBooking>>(
                value: trips,
                onRetry: () => ref.invalidate(c2cMyTripsProvider),
                data: (list) => list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text('No City to City trips yet. Plan one above.',
                            key: const ValueKey('c2c-no-trips'), style: t.textTheme.bodyMedium?.copyWith(color: look.muted)),
                      )
                    : Column(children: [
                        for (final b in list) ...[
                          _TripRow(booking: b),
                          const SizedBox(height: 8),
                        ],
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripRow extends StatelessWidget {
  const _TripRow({required this.booking});
  final C2cBooking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final live = !b.status.ended;
    return Material(
      color: look.box,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('c2c-trip-${b.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => openC2cTrip(context, b.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Icon(Icons.route, color: live ? look.accent : look.mutedOnBox),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b.route, style: t.textTheme.titleSmall?.copyWith(color: look.onBox)),
                Text('${c2cDayTime(b.leaves)} · ${b.status.label}',
                    style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(c2cMoney(b.price, b.currency),
                  style: t.textTheme.titleSmall?.copyWith(color: look.onBox, fontWeight: FontWeight.w600)),
              Text('whole car', style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
            ]),
          ]),
        ),
      ),
    );
  }
}
