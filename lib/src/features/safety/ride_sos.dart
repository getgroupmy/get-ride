// SOS during a ride, for the passenger and the driver alike: a red button
// floating on the map, low on the left (the map's own view and recenter
// buttons are on the right), riding up with the sheet. It offers to call
// the emergency number or to text the emergency contacts the location, and
// whichever is chosen GET.ride's safety team is alerted too (migration
// 0193), with the phone's location kept up to date for them.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/sos.dart';
import '../../data/models.dart';
import '../../data/safety_incident_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart';
import '../profile/emergency_contacts_screen.dart';
import 'safety_screen.dart';
import '../../widgets/page_style_host.dart';

/// Call [emergencyNumber], or alert the emergency contacts with the
/// location (and, for a passenger, the driver and car). Any choice also
/// alerts GET.ride's safety team about [rideId]; the other person on the
/// ride is not told.
Future<void> showRideSos(BuildContext context, WidgetRef ref, {String? driver, String? plate, String? rideId}) async {
  final choice = await showAppSheet<String>(id: 'ride-sos.show-ride-sos',
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              "Whichever you choose, GET.ride's safety team is told where you are.",
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ),
          ListTile(
            key: const ValueKey('sos-ops'),
            leading: const Icon(Icons.support_agent),
            title: const Text('Alert the GET.ride safety team'),
            subtitle: const Text('They see your trip and location, and get in touch'),
            onTap: () => Navigator.pop(c, 'ops'),
          ),
          ListTile(
            key: const ValueKey('sos-call'),
            leading: const Icon(Icons.call),
            title: const Text('Call $emergencyNumber'),
            subtitle: const Text('Police, ambulance and fire'),
            onTap: () => Navigator.pop(c, 'call'),
          ),
          ListTile(
            key: const ValueKey('sos-contacts'),
            leading: const Icon(Icons.sms_outlined),
            title: const Text('Alert my emergency contacts'),
            subtitle: Text(driver == null ? 'SMS with your location' : 'SMS with your location, driver and car'),
            onTap: () => Navigator.pop(c, 'contacts'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  unawaited(_alertOps(ref, rideId));
  if (choice == 'ops') {
    showInfo(context, "GET.ride's safety team has been alerted with your location.");
    return;
  }
  if (choice == 'call') {
    await launchUrl(Uri(scheme: 'tel', path: emergencyNumber));
    return;
  }
  List<EmergencyContact> contacts;
  try {
    contacts = await ref.read(emergencyContactsProvider.future);
  } catch (_) {
    contacts = const [];
  }
  if (!context.mounted) return;
  await sendSos(context, contacts, driver: driver, plate: plate);
}

/// Raises the safety incident with where the phone is, then keeps the
/// location coming for the admin's minutes. Best effort: an emergency call
/// or text never waits on it.
Future<void> _alertOps(WidgetRef ref, String? rideId) async {
  final sharer = ref.read(sosLocationSharerProvider);
  try {
    final at = await sharer.position();
    final id = await ref
        .read(safetyIncidentRepositoryProvider)
        .raise(rideId: rideId, lat: at?.latitude, lng: at?.longitude);
    sharer.start(id);
  } catch (_) {}
}

/// The floating SOS button: put it in a Stack over the ride's map.
class RideSosFab extends StatelessWidget {
  const RideSosFab({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MapBottomInset.listen(
      context,
      (inset) => Stack(
        children: [
          Positioned(
            left: 12,
            bottom: mapAttributionClearance + inset + 16,
            child: FloatingActionButton(
              key: const ValueKey('ride-sos'),
              heroTag: null,
              tooltip: 'SOS · Emergency',
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
              onPressed: onPressed,
              child: const Icon(Icons.sos, size: 30),
            ),
          ),
        ],
      ),
    );
  }
}
