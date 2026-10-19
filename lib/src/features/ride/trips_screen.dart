import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/trip_history.dart';
import '../../data/scheduled_ride_repository.dart' show scheduledRidesConfigProvider;
import '../../widgets/offline_strip.dart';
import '../../widgets/side_menu_host.dart';
import 'scheduled_rides_screen.dart' show ScheduledRidesList;
import 'trip_history_view.dart';

/// Trips, on the user side: the requests this person made as a rider, and
/// (while scheduled rides are on) a Scheduled tab with their bookings. The
/// trips they drove are on the partner side (Drive → Trip history).
class TripsScreen extends ConsumerWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduled = ref.watch(scheduledRidesConfigProvider).value?.enabled ?? false;
    if (!scheduled) {
      return Scaffold(
        appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Trips')),
        body: OfflineStrip.over(const TripHistoryView(role: TripHistoryRole.rider)),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: sideMenuLeading(context),
          title: const Text('Trips'),
          bottom: const TabBar(
            tabs: [
              Tab(key: ValueKey('trips-tab-history'), text: 'Trips'),
              Tab(key: ValueKey('trips-tab-scheduled'), text: 'Scheduled'),
            ],
          ),
        ),
        body: OfflineStrip.over(
          const TabBarView(
            children: [
              TripHistoryView(role: TripHistoryRole.rider),
              ScheduledRidesList(),
            ],
          ),
        ),
      ),
    );
  }
}
