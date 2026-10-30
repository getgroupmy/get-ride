// myGiG part C (0331): myGiG hotspots. From the fire button on the driver's
// home map or the side menu: where myGiG passengers wave most (counts per
// area from the last weeks of myGiG rides; areas under the admin's minimum
// hidden) and the busiest hours on this weekday. Counts only: no passenger
// details, no exact pickups. Tap an area to drive there.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/mygig_extras.dart';
import '../../core/navigation_app.dart' show navigationUri;
import '../../data/mygig_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/ride_map.dart';
import '../partner/partner_trip_screen.dart' show tripFixProvider;

const mygigHotspotsPath = '/drive/mygig/hotspots';

/// Whether the admin shows hotspots where the driver is (settings.hotspots.enabled).
bool mygigHotspotsOn(Map<String, dynamic> settings) {
  final h = settings['hotspots'];
  return h is! Map || h['enabled'] != false;
}

final _hereProvider = FutureProvider.autoDispose<LatLng?>((ref) => ref.read(tripFixProvider)());

final _hotspotsProvider = FutureProvider.autoDispose.family<MygigHotspots, LatLng>(
  (ref, at) => ref.watch(mygigRepositoryProvider).hotspots(lat: at.latitude, lng: at.longitude),
);

class MygigHotspotsScreen extends ConsumerWidget {
  const MygigHotspotsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final here = ref.watch(_hereProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('myGiG hotspots')),
      body: AsyncView(
        value: here,
        onRetry: () => ref.invalidate(_hereProvider),
        data: (at) => at == null
            ? ListView(children: const [
                EmptyState(
                  icon: Icons.location_off_outlined,
                  title: 'Where are you?',
                  message: 'Turn on location to see where myGiG passengers wave near you.',
                ),
              ])
            : AsyncView(
                value: ref.watch(_hotspotsProvider(at)),
                onRetry: () => ref.invalidate(_hotspotsProvider(at)),
                data: (h) => MygigHotspotsBody(hotspots: h, here: at),
              ),
      ),
    );
  }
}

class MygigHotspotsBody extends ConsumerWidget {
  const MygigHotspotsBody({super.key, required this.hotspots, required this.here});
  final MygigHotspots hotspots;
  final LatLng here;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final h = hotspots;
    if (!h.enabled) {
      return ListView(children: const [
        EmptyState(
          key: ValueKey('mygig-hotspots-off'),
          icon: Icons.local_fire_department_outlined,
          title: 'Hotspots aren’t shown here',
          message: 'get.ride hasn’t turned on myGiG hotspots in this area.',
        ),
      ]);
    }
    final areas = h.areas;
    final top = areas.isEmpty ? 1 : areas.map((a) => a.count).reduce((a, b) => a > b ? a : b);
    return ResponsiveCenter(
      maxWidth: 760,
      child: ListView(
        key: const ValueKey('mygig-hotspots'),
        children: [
          SizedBox(
            height: 240,
            child: RideMap(
              me: here,
              framed: [for (final a in areas) LatLng(a.lat, a.lng)],
              extraMarkers: [
                for (final a in areas)
                  Marker(
                    point: LatLng(a.lat, a.lng),
                    width: 40 + 50 * a.count / top,
                    height: 40 + 50 * a.count / top,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: t.colorScheme.error.withValues(alpha: 0.25),
                          border: Border.all(color: t.colorScheme.error, width: 1.5),
                        ),
                        child: Center(
                          child: Text('${a.count}', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurface)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Busiest areas', style: t.textTheme.titleMedium),
          ),
          if (areas.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Not enough myGiG rides around you yet to show an area.', key: ValueKey('mygig-hotspots-none')),
            )
          else
            for (final a in areas)
              ListTile(
                key: ValueKey('mygig-hotspot-${a.lat}-${a.lng}'),
                leading: Icon(Icons.local_fire_department, color: t.colorScheme.error),
                title: Text(a.name),
                subtitle: Text('${a.count} myGiG ride${a.count == 1 ? '' : 's'} in the last ${h.weeks} weeks'
                    '${a.nowCount > 0 ? ', ${a.nowCount} around this hour' : ''} · ${a.km.toStringAsFixed(1)} km away'),
                trailing: IconButton(
                  tooltip: 'Drive to ${a.name}',
                  icon: const Icon(Icons.navigation_outlined),
                  onPressed: () => launchUrl(navigationUri(ref.read(navigationAppProvider), a.lat, a.lng),
                      mode: LaunchMode.externalApplication),
                ),
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Best hours today', style: t.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: h.hasHours
                ? MygigHourBars(counts: h.hours, now: h.hourNow)
                : const Text('Not enough myGiG rides here on this day yet.'),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${h.hasHours ? '${mygigBestHoursText(h.hours)} ' : ''}From myGiG rides around you in the last ${h.weeks} weeks. '
              'Counts only, no passenger details.',
              style: t.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rides by hour, the busiest in the strongest colour; the hour now marked.
class MygigHourBars extends StatelessWidget {
  const MygigHourBars({super.key, required this.counts, required this.now});
  final List<int> counts;
  final int now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final top = counts.fold<int>(0, (a, b) => a > b ? a : b);
    final best = mygigBestHours(counts, n: 1).firstOrNull;
    return Semantics(
      label: 'myGiG rides by hour today. ${mygigBestHoursText(counts)}',
      child: SizedBox(
        key: const ValueKey('mygig-hour-bars'),
        height: 120,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < 24; i++)
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Container(
                  height: top == 0 ? 0 : 90 * counts[i] / top,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                    color: i == best
                        ? t.colorScheme.error
                        : i == now
                            ? t.colorScheme.primary
                            : t.colorScheme.primary.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 16,
                  child: i % 4 == 0
                      ? FittedBox(child: Text(mygigHourLabel(i).replaceAll(' ', ''), style: t.textTheme.labelSmall))
                      : null,
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}
