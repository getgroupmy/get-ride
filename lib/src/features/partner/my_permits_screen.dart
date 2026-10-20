// The driver's permits, any time (side menu > My permit, Vehicles > [plate]
// > Permit, and the trip screen's button): each vehicle permit and the
// driver's own, with their status, the warning before expiry, why the
// driver can't go online (where the country requires permits) and the file.
// The driver never uploads a permit the country's GET.ride uploads.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/date_order.dart';
import '../../core/permits.dart';
import '../../data/permits_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/permit_views.dart';

/// Today, for tests.
final permitsTodayProvider = Provider<DateTime Function()>((_) => DateTime.now);

class MyPermitsScreen extends ConsumerWidget {
  const MyPermitsScreen({super.key, this.vehicleId});

  /// One vehicle's (Vehicles > [plate] > Permit); else the one being driven.
  final String? vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myPermitsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My permit')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: 'Could not load your permits',
          message: errorText(e),
          action: FilledButton(onPressed: () => ref.invalidate(myPermitsProvider), child: const Text('Try again')),
        ),
        data: (my) => MyPermitsBody(my: my, vehicleId: vehicleId, today: ref.watch(permitsTodayProvider)()),
      ),
    );
  }
}

/// The page's content, for one vehicle or all of them.
class MyPermitsBody extends StatelessWidget {
  const MyPermitsBody({super.key, required this.my, this.vehicleId, required this.today});
  final MyPermits my;
  final String? vehicleId;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final vehicles = vehicleId == null
        ? (my.current == null ? my.vehicles : [my.current!])
        : my.vehicles.where((v) => v.vehicleId == vehicleId).toList();
    final shown = vehicles.where((v) => v.permits.isNotEmpty).toList();
    if (shown.isEmpty && my.driverPermits.isEmpty) {
      return const EmptyState(
        icon: Icons.verified_user_outlined,
        title: 'No permits',
        message: 'No permit is needed for your vehicle where it is registered.',
      );
    }
    return ResponsiveCenter(
      maxWidth: 640,
      child: ListView(
        key: const ValueKey('my-permits'),
        padding: const EdgeInsets.all(16),
        children: [
          for (final v in shown) ...[
            for (final p in v.permits)
              if (driverPermitBanner(p, today, bypassUntil: v.bypassUntil, plate: v.plate) case final b?)
                PermitBanner(key: ValueKey('permit-banner-${p.typeId}'), title: b.title, body: b.body, blocked: b.blocked),
            VehiclePermitsCard(vehicle: v, today: today),
            const SizedBox(height: 16),
          ],
          if (my.driverPermits.isNotEmpty) ...[
            Text('Your own permits', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final p in my.driverPermits) ...[
              if (driverPermitBanner(p, today) case final b?)
                PermitBanner(key: ValueKey('permit-banner-${p.typeId}'), title: b.title, body: b.body, blocked: b.blocked),
              PermitBox(permit: p, badge: permitBadge(p, today)),
              const SizedBox(height: 10),
            ],
          ],
          Text(
            'Show it to an enforcement officer when asked.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// One vehicle: its plate, car, bypass note and permit boxes.
class VehiclePermitsCard extends StatelessWidget {
  const VehiclePermitsCard({super.key, required this.vehicle, required this.today});
  final VehiclePermits vehicle;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final v = vehicle;
    final bypass = v.status == PermitStatus.bypass && v.bypassUntil != null;
    return Column(
      key: ValueKey('vehicle-permits-${v.vehicleId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PermitVehicleLine(plate: v.plate, colours: v.colours, label: v.label, detail: v.energy),
        if (bypass) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: PermitBadge(
              key: const ValueKey('permit-bypass-note'),
              text: 'Temporary pass until ${formatDateForUser(v.bypassUntil)} · no permit shown to passengers',
              tone: PermitBadgeTone.warn,
            ),
          ),
        ],
        for (final p in v.permits) ...[
          const SizedBox(height: 10),
          PermitBox(permit: p, badge: permitBadge(p, today, bypassUntil: v.bypassUntil)),
        ],
      ],
    );
  }
}

/// The warning over a permit: expiring (amber) or blocking (red), with
/// Contact support when it blocks.
class PermitBanner extends StatelessWidget {
  const PermitBanner({super.key, required this.title, required this.body, required this.blocked});
  final String title;
  final String body;
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = permitToneColours(blocked ? PermitBadgeTone.bad : PermitBadgeTone.warn, t.brightness);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.fg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.textTheme.titleSmall?.copyWith(color: c.fg, fontWeight: FontWeight.w700)),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(body, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurface)),
          ],
          if (blocked) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('permit-contact-support'),
              onPressed: () => GoRouter.maybeOf(context)?.push('/account/support'),
              child: const Text('Contact support'),
            ),
          ],
        ],
      ),
    );
  }
}

/// The trip screen's small button: the vehicle being driven's permits in a
/// sheet ("Vehicle permit · expiring").
class DriverPermitButton extends ConsumerWidget {
  const DriverPermitButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final my = ref.watch(myPermitsProvider).value;
    final v = my?.current;
    if (v == null) return const SizedBox.shrink();
    final items = [...v.permits, ...my!.driverPermits];
    final label = permitButtonLabel(items);
    if (label == null) return const SizedBox.shrink();
    final today = ref.watch(permitsTodayProvider)();
    final worst = [for (final p in items) permitBadge(p, today, bypassUntil: v.bypassUntil).tone];
    final note = worst.contains(PermitBadgeTone.bad)
        ? 'expired'
        : (worst.contains(PermitBadgeTone.warn) ? (v.onBypass ? 'bypass' : 'expiring') : null);
    return PermitButton(
      key: const ValueKey('driver-permit-button'),
      label: label,
      note: note,
      onPressed: () => showAppSheet<void>(
        id: 'partner-trip.my-permits',
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => PermitSheetBody(
          permits: items,
          plate: v.plate,
          colours: v.colours,
          vehicleLabel: v.label,
          vehicleDetail: v.energy,
          badges: true,
          bypassUntil: v.bypassUntil,
          onClose: () => Navigator.pop(c),
        ),
      ),
    );
  }
}
