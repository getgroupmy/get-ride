import 'package:flutter/material.dart';

import '../core/ride_stops.dart';
import '../data/geo_service.dart';

/// The numbered stops between pickup and drop-off, for the trip cards.
class RideStopTiles extends StatelessWidget {
  const RideStopTiles({super.key, required this.stops, this.onNavigate});
  final List<Place> stops;

  /// When set (the driver's screen), each stop gets a navigate button.
  final ValueChanged<Place>? onNavigate;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < stops.length; i++)
        ListTile(
          key: ValueKey('trip-stop-$i'),
          leading: CircleAvatar(
            radius: 12,
            backgroundColor: Colors.orange.shade800,
            child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          title: Text(stops[i].name),
          subtitle: Text(
            [
              stopLabel(i),
              if (stops[i].address.isNotEmpty && stops[i].address != stops[i].name) stops[i].address,
            ].join(' · '),
            maxLines: 2,
          ),
          trailing: onNavigate == null
              ? null
              : IconButton(
                  tooltip: 'Navigate to ${stopLabel(i).toLowerCase()}',
                  icon: const Icon(Icons.navigation_outlined),
                  onPressed: () => onNavigate!(stops[i]),
                ),
        ),
    ],
  );
}
