import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../core/format.dart';
import '../core/route_estimate.dart';

/// A toll mark on the map: its name in a pill above a toll badge (Expo's
/// ride-confirm toll marker). Tapping it lists the booths.
Marker tollMarker(TollMark m, {VoidCallback? onTap}) => Marker(
  point: LatLng(m.lat, m.lng),
  width: 120,
  height: 58,
  alignment: Alignment.topCenter,
  child: GestureDetector(
    key: ValueKey('toll-mark-${m.label}'),
    onTap: onTap,
    child: Builder(
      builder: (context) {
        final t = Theme.of(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: t.colorScheme.surface,
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
              ),
              child: Text(
                m.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 2),
            const CircleAvatar(
              radius: 15,
              backgroundColor: Color(0xFFF59E0B),
              child: Icon(Icons.toll, size: 18, color: Colors.white),
            ),
          ],
        );
      },
    ),
  ),
);

/// "Toll Booths on Route": each booth with its estimated charge and, where
/// known, its position, and the total.
Future<void> showTollBooths(BuildContext context, RouteEstimate e) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (c) {
    final t = Theme.of(c);
    final n = tollBoothCount(e);
    final total = e.tollsToShow;
    final each = e.tolls.isNotEmpty ? null : (total != null && n > 0 ? total / n : null);
    final rows = e.tolls.isNotEmpty ? e.tolls : [for (var i = 0; i < n; i++) TollBooth(charge: each ?? 0)];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
        child: ListView(
          key: const ValueKey('toll-booths-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('Toll Booths on Route', style: t.textTheme.titleLarge),
            const SizedBox(height: 8),
            for (var i = 0; i < rows.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'TOLL',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFFB45309)),
                  ),
                ),
                title: Text(rows[i].name ?? 'Toll Plaza ${i + 1}'),
                subtitle: rows[i].located
                    ? Text('${rows[i].lat!.toStringAsFixed(5)}, ${rows[i].lng!.toStringAsFixed(5)}')
                    : null,
                trailing: Text('Est. ${formatMoney(rows[i].charge, AppConfig.currency)}'),
              ),
            if (total != null) ...[
              const Divider(),
              Row(
                children: [
                  Expanded(child: Text('Total Estimated Toll', style: t.textTheme.titleSmall)),
                  Text(formatMoney(total, AppConfig.currency), style: t.textTheme.titleSmall),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  },
);
