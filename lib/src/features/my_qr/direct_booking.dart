// GET.now on the rider's side (migration 0161): a driver's code scanned and
// "Book this driver" pressed. The booking itself is the ordinary one (pickup,
// destination, service, fare); this holds which driver it goes to until it
// is booked or the rider drops it, and remembers who a direct request went
// to so the searching screen can name them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/my_ride.dart' show FavouriteDriver;

/// A booking to make directly with the driver whose GET.now code was
/// scanned: the scanned token goes to `createRequest(directQrToken:)`.
class DirectBooking {
  const DirectBooking({required this.token, this.driver});

  final String token;

  /// What the code resolved to (name, photo, vehicle); null when the
  /// server sent no card.
  final FavouriteDriver? driver;

  String get driverName => driver?.name.trim().isNotEmpty == true ? driver!.name.trim() : 'this driver';
}

class DirectBookingNotifier extends Notifier<DirectBooking?> {
  @override
  DirectBooking? build() => null;

  void set(DirectBooking booking) => state = booking;

  void clear() => state = null;
}

/// The direct booking being made, if any.
final directBookingProvider = NotifierProvider<DirectBookingNotifier, DirectBooking?>(DirectBookingNotifier.new);

class DirectBookingNamesNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  void remember(String requestId, String name) => state = {...state, requestId: name};
}

/// Who each direct request booked in this session went to (request id →
/// driver name), for the searching banner.
final directBookingNamesProvider = NotifierProvider<DirectBookingNamesNotifier, Map<String, String>>(
  DirectBookingNamesNotifier.new,
);

/// The confirm step's row while booking a driver directly, in place of the
/// My Ride switch: who it goes to, and a way to book normally instead.
class DirectBookingConfirmRow extends StatelessWidget {
  const DirectBookingConfirmRow({super.key, required this.booking, required this.onCancel});

  final DirectBooking booking;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      key: const ValueKey('direct-booking-row'),
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: t.colorScheme.primaryContainer, shape: BoxShape.circle),
          child: Icon(Icons.qr_code_2, size: 18, color: t.colorScheme.onPrimaryContainer),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Booking ${booking.driverName} directly',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                'Only this driver gets your request',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('direct-booking-cancel'),
          tooltip: 'Book any driver instead',
          icon: const Icon(Icons.close),
          onPressed: onCancel,
        ),
      ],
    );
  }
}
