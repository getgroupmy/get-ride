import 'package:flutter/material.dart';

import '../../core/trip_history.dart';
import '../../widgets/side_menu_host.dart';
import 'trip_history_view.dart';

/// Trips, on the user side: the requests this person made as a rider. The
/// trips they drove are on the partner side (Drive → Trip history).
class TripsScreen extends StatelessWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Trips')),
    body: const TripHistoryView(role: TripHistoryRole.rider),
  );
}
