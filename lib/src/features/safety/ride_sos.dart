// SOS during a ride, for the passenger and the driver alike: a red button
// floating on the map, low on the left (the map's own view and recenter
// buttons are on the right), riding up with the sheet. It offers to call
// the emergency number or to text the emergency contacts the location.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/sos.dart';
import '../../data/models.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart';
import '../profile/emergency_contacts_screen.dart';
import 'safety_screen.dart';

/// Call [emergencyNumber], or alert the emergency contacts with the
/// location (and, for a passenger, the driver and car).
Future<void> showRideSos(BuildContext context, WidgetRef ref, {String? driver, String? plate}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
