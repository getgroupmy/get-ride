import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hourly_hire.dart' show RideHire, hireAdminDetails;
import 'hire_booking_view.dart';
import 'hire_bookings_screen.dart' show hireBookingsPath;
import 'package:go_router/go_router.dart';
import '../../core/format.dart';
import '../../core/region_time.dart' show formatInZone;
import '../../data/models.dart';
import '../../features/ride/freight_parts.dart' show FreightCargoView, FreightNoticesView, FreightProofView;
import '../../features/ride/courier_parts.dart' show CourierCodeCard;
import '../../features/ride/pet_parts.dart' show RidePetsView;
import '../../features/ride/assistance_parts.dart' show OptionChargesLine, RideAssistanceView;
import '../../core/ride_option_settings.dart' show RideOptionKind;
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_filters.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';
import '../widgets/trip_audio_panel.dart';

/// A row's second line, as the rider's trip list words it: when (in the
/// trip's region), then who: "12 Mar 2026, 3:15 PM · Rider Aisyah · Driver Ali".
String adminRideSubtitle(RideRequest r) => [
      formatInZone(r.createdAt, r.timezone),
      // Hourly hire (0326).
      if (RideHire.fromRow(r.raw) case final h?) h.heading,
      'Rider ${(r.riderName ?? '').trim().isEmpty ? 'unknown' : r.riderName!.trim()}',
      if ((r.partnerName ?? '').trim().isNotEmpty) 'Driver ${r.partnerName!.trim()}',
    ].join(' · ');

final adminRidesProvider = FutureProvider.autoDispose.family<List<RideRequest>, String>((ref, group) async {
  ref.watchAdminLive('ride_requests');
  final rows = await ref.watch(adminRepositoryProvider).rides(statuses: rideStatusGroups[group]);
  return rows.map(RideRequest.new).toList();
});

class AdminRidesScreen extends ConsumerStatefulWidget {
  const AdminRidesScreen({super.key, this.initialFilter, this.openRideId});
  final String? initialFilter;

  /// A ride to open as the page opens (God View's Open ride).
  final String? openRideId;

  @override
  ConsumerState<AdminRidesScreen> createState() => _AdminRidesScreenState();
}

class _AdminRidesScreenState extends ConsumerState<AdminRidesScreen> {
  late String _group = rideStatusGroups.containsKey(widget.initialFilter) ? widget.initialFilter! : 'active';
  String _query = '';

  @override
  void initState() {
    super.initState();
    final id = widget.openRideId;
    if (id != null && id.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _openById(id));
  }

  Future<void> _openById(String id) async {
    try {
      final row = await ref.read(adminRepositoryProvider).ride(id);
      if (!mounted) return;
      if (row == null) {
        showInfo(context, 'That ride is no longer there.');
        return;
      }
      _open(RideRequest(row));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _open(RideRequest r) {
    final canEdit = ref.read(moduleAccessProvider('rides')) == AccessLevel.edit;
    showAdminSheet<void>(
      context,
      title: '${r.pickupLabel} to ${r.dropLabel}',
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [StatusChip(r.raw['status'] as String?)]),
        const SizedBox(height: 12),
        DetailTable({
          'Request ID': r.id,
          'Service': r.service,
          'Fare': formatMoney(r.effectiveFare, r.currency),
          'Offered fare': r.offeredFare == null ? null : formatMoney(r.offeredFare, r.currency),
          'Payment': r.paymentMode,
          'Distance': formatDistance(r.distanceKm),
          'Rider': [r.riderName, r.riderPhone].whereType<String>().join(' · '),
          'Partner': [r.partnerName, r.partnerPhone].whereType<String>().join(' · '),
          'Vehicle': [r.partnerVehicle, r.partnerPlate].whereType<String>().join(' · '),
          'Pickup': r.pickupAddress,
          'Drop-off': r.dropAddress,
          'Note': r.note,
          'Area': [r.raw['city'], r.raw['state'], r.raw['country']].whereType<String>().join(', '),
          'Device / IP': [r.raw['device_os'], r.raw['ip_address']].whereType<String>().join(' · '),
          'Created': dateText(r.raw['created_at']),
          'Accepted': dateText(r.raw['accepted_at']),
          'Started': dateText(r.raw['started_at']),
          'Completed': dateText(r.raw['completed_at']),
          'Cancelled': dateText(r.raw['cancelled_at']),
          'Cancel reason': r.raw['cancel_reason'],
          // Hourly hire (0326): the package, the clock, extensions and the settled lines.
          if (RideHire.fromRow(r.raw) case final h?) ...hireAdminDetails(h, (v) => formatMoney(v, r.currency)),
          // Freight (0267).
          // Courier (0268).
          'Parcel size': r.parcelSize,
          'Who pays': r.isCourier ? (r.recipientPays ? 'Recipient, in cash on delivery' : 'Sender') : null,
          'Code confirmed': r.isCourier ? (r.deliveryCodeOkAt == null ? 'Not yet' : dateText(r.raw['delivery_code_ok_at'])) : null,
          'Declared value': r.declaredValue == null ? null : formatMoney(r.declaredValue, r.currency),
          'Recipient': [?r.recipientName, ?r.recipientPhone].join(' · '),
          'Waiting fee': (r.waitingFee ?? 0) > 0 ? '${formatMoney(r.waitingFee, r.currency)} (${r.waitingMinutes} min)' : null,
          // City rides (0314).
          'Waiting charge': (r.waitingCharge ?? 0) > 0
              ? '${formatMoney(r.waitingCharge, r.currency)} (${r.cityWaitingMinutes} min)'
              : null,
          'Bags': (r.luggage ?? 0) > 0 ? '${r.luggage}' : null,
          'Cancel fee': r.freightCancelFee == null ? null : '${formatMoney(r.freightCancelFee, r.currency)} (${r.raw['freight_cancel_fee_status']})',
          'Commission': r.raw['commission_amount'] == null
              ? null
              : '${formatMoney(r.raw['commission_amount'] as num, r.currency)} '
                  '(${((r.raw['commission_rate'] as num? ?? 0) * 100).toStringAsFixed(1)}%)',
        }),
        // Hire for several days (0327): the booking and every day.
        if (r.raw['hire_booking_id'] case final String bookingId) ...[
          const SizedBox(height: 12),
          AdminHireBookingView(bookingId: bookingId, canEdit: canEdit),
        ],
        // Trip audio (0315): the driver's VoiceProtection and the rider's
        // audio protection recordings of this ride, to request and play.
        const SizedBox(height: 12),
        TripAudioPanel.forRide(key: const ValueKey('admin-ride-audio'), rideId: r.id, canEdit: canEdit),
        // Freight (0267): the cargo and its photo.
        if (r.isFreight) ...[
          const SizedBox(height: 12),
          FreightCargoView(key: const ValueKey('admin-ride-freight'), request: r, title: r.isCourier ? 'Parcel' : 'Cargo'),
          const SizedBox(height: 12),
          FreightProofView(request: r),
          const SizedBox(height: 8),
          FreightNoticesView(rideId: r.id),
          // Courier (0268): the code, for support.
          if (r.isCourier) ...[
            const SizedBox(height: 8),
            CourierCodeCard(request: r),
          ],
        ],
        // "Pet with me" (0247): an open request's photos wait aside.
        if (r.pets.isNotEmpty) ...[
          const SizedBox(height: 12),
          RidePetsView(
            key: const ValueKey('admin-ride-pets'),
            pets: r.pets,
            title: r.renamedOption(RideOptionKind.pet) ?? 'Pets riding along',
          ),
        ],
        // "Assistance required" (0248): an open request's note waits aside.
        if (r.assistance case final help?) ...[
          const SizedBox(height: 12),
          RideAssistanceView(
            key: const ValueKey('admin-ride-assistance'),
            assistance: help,
            title: r.renamedOption(RideOptionKind.assistance),
          ),
        ],
        if (r.optionCharges.isNotEmpty) ...[
          const SizedBox(height: 8),
          OptionChargesLine(lines: r.optionCharges, money: (v) => formatMoney(v, r.currency)),
        ],
        if (canEdit && r.status.isOngoing) ...[
          const SizedBox(height: 16),
          BusyButton.outlined(
            icon: const Icon(Icons.cancel_outlined),
            child: const Text('Cancel this ride'),

            onPressed: () async {
              if (!await confirm(ctx, 'Cancel ride?', 'Both the rider and the partner will see it as cancelled.',
                  ok: 'Cancel ride')) {
                return;
              }
              if (!ctx.mounted) return;
              final ok = await runAdminAction(
                ctx,
                () => ref.read(adminRepositoryProvider).adminCancelRide(r.id, 'Cancelled by admin'),
                success: 'Ride cancelled',
              );
              if (ok) {
                ref.invalidate(adminRidesProvider(_group));
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      title: 'Rides',
      module: 'rides',
      actions: [
        // Hire for several days (0327, 0328): every booking, before day 1 too.
        IconButton(
          key: const ValueKey('rides-hire-bookings'),
          tooltip: 'Hire bookings',
          icon: const Icon(Icons.event_repeat_outlined),
          onPressed: () => context.push(hireBookingsPath),
        ),
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(adminRidesProvider(_group))),
      ],
      body: Column(children: [
        FilterBar(
          filters: const {
            'active': 'In progress',
            'open': 'Open',
            'completed': 'Completed',
            'cancelled': 'Cancelled / expired',
            'all': 'All',
          },
          selected: _group,
          onSelected: (g) => setState(() => _group = g),
          onSearch: (q) => setState(() => _query = q),
          hint: 'Search rider, partner, place, plate…',
        ),
        Expanded(
          child: AsyncView(
            value: ref.watch(adminRidesProvider(_group)),
            onRetry: () => ref.invalidate(adminRidesProvider(_group)),
            data: (rides) {
              final q = _query.trim().toLowerCase();
              final list = q.isEmpty
                  ? rides
                  : rides
                      .where((r) => [
                            r.riderName, r.riderPhone, r.partnerName, r.partnerPhone, r.partnerPlate,
                            r.pickupLabel, r.dropLabel, r.id,
                          ].whereType<String>().any((s) => s.toLowerCase().contains(q)))
                      .toList();
              if (list.isEmpty) return const EmptyState(icon: Icons.local_taxi_outlined, title: 'No rides');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = list[i];
                  return ListTile(
                    title: Text('${r.pickupLabel} to ${r.dropLabel}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(adminRideSubtitle(r)),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(formatMoney(r.effectiveFare, r.currency)),
                        const SizedBox(height: 4),
                        StatusChip(r.raw['status'] as String?),
                      ],
                    ),
                    onTap: () => _open(r),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
