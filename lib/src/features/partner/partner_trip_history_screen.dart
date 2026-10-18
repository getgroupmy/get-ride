import 'package:flutter/material.dart';

import '../../core/trip_history.dart';
import '../../widgets/back_or_go_button.dart';
import '../ride/trip_history_view.dart';

/// Drive → Trip history, on the partner side: the trips this person took as
/// a partner. The rides they booked are on the user side (Trips).
class PartnerTripHistoryScreen extends StatelessWidget {
  const PartnerTripHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(leading: const BackOrGoButton(fallback: '/drive'), title: const Text('Trip history')),
    body: const TripHistoryView(role: TripHistoryRole.partner),
  );
}
