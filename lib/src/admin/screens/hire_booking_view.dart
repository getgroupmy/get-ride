// A hire for several days on the admin's ride details (migration 0327): the
// booking (its price, what was paid, its state) and every day with its
// pickup, status and whether a driver has it; cancelling it (free).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/hourly_hire.dart' show hireClock;
import '../../core/multi_day_hire.dart';
import '../../data/hourly_hire_repository.dart';
import '../../widgets/common.dart' show AsyncView, showError, showInfo;
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';

typedef HireBookingDay = ({String id, int day, DateTime at, String status, String? partnerId, String? rideId});

final adminHireBookingProvider = FutureProvider.autoDispose
    .family<({HireDaysBooking? booking, List<HireBookingDay> days}), String>((ref, id) async {
  final repo = ref.watch(hourlyHireRepositoryProvider);
  return (booking: await repo.booking(id), days: await repo.bookingDays(id));
});

/// "Day 2 of 3 · Mon 2 Nov, 9:00 am · released · driver set".
String hireBookingDayLine(HireBookingDay d, int days) =>
    '${hireDayText(d.day, days)} · ${hireDate(d.at)}, ${hireClock(d.at)} · ${d.status}'
    ' · ${d.partnerId == null ? 'no driver yet' : 'driver set'}';

class AdminHireBookingView extends ConsumerWidget {
  const AdminHireBookingView({super.key, required this.bookingId, required this.canEdit});

  final String bookingId;
  final bool canEdit;

  /// The admin gives every day still to come (or day [day]) to a driver
  /// they choose (0328).
  Future<void> _assign(BuildContext context, WidgetRef ref, {int? day}) async {
    final repo = ref.read(hourlyHireRepositoryProvider);
    try {
      final drivers = await repo.adminDrivers(bookingId, day: day);
      if (!context.mounted) return;
      if (drivers.isEmpty) {
        showInfo(context, 'No approved driver takes hire yet.');
        return;
      }
      final picked = await showSearchPicker<String>(
        context,
        title: day == null ? 'Give every day still to come to' : 'Give day $day to',
        choices: [
          for (final d in drivers)
            (
              value: d.id,
              label: d.name,
              subtitle: [?d.phone, d.free ? 'free' : 'has a ride that clashes'].join(' · '),
              leading: null,
            ),
        ],
      );
      if (picked == null || !context.mounted) return;
      await runAdminAction(context, () => repo.adminAssign(bookingId, picked, day: day),
          success: day == null ? 'Every day still to come is the driver\'s' : 'Day $day is the driver\'s');
      ref.invalidate(adminHireBookingProvider(bookingId));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return AsyncView(
      value: ref.watch(adminHireBookingProvider(bookingId)),
      onRetry: () => ref.invalidate(adminHireBookingProvider(bookingId)),
      data: (v) {
        final b = v.booking;
        if (b == null) return const SizedBox.shrink();
        String money(double x) => formatMoney(x, b.currency ?? 'MYR');
        return Card(
          key: ValueKey('admin-hire-booking-${b.id}'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(b.title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              DetailTable({
                'Booking': b.id,
                'Days': b.span,
                'Km': b.kmByPeriod && b.kmPerPeriod != null
                    ? '${b.kmPerPeriod!.round()} km a ${b.package == hirePackageMonthly ? 'month' : 'week'}, '
                          'extra km at its end'
                    : null,
                'Ending with notice': b.noticeUntil == null ? null : 'Days from ${hireDate(b.noticeUntil!)} cancelled',
                'Status': b.statusLabel,
                'Price': money(b.price),
                'Payment': b.paymentText(money),
                'Refunded': b.refundedAmount > 0 ? money(b.refundedAmount) : null,
                'Kept on cancelling': b.cancelFee > 0 ? money(b.cancelFee) : null,
                'Same driver': b.sameDriver ? (b.splitAt == null ? 'Yes' : 'Yes, split at the cut-off') : 'No',
              }),
              const SizedBox(height: 4),
              for (final d in v.days)
                Row(children: [
                  Expanded(
                    child: Text(hireBookingDayLine(d, b.days), key: ValueKey('admin-hire-day-${d.day}'),
                        style: t.textTheme.bodySmall),
                  ),
                  if (canEdit && b.open && (d.status == 'scheduled' || d.status == 'assigned') &&
                      d.at.isAfter(DateTime.now()))
                    IconButton(
                      key: ValueKey('admin-hire-day-assign-${d.day}'),
                      tooltip: 'Give day ${d.day} to a driver',
                      icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
                      onPressed: () => _assign(context, ref, day: d.day),
                    ),
                ]),
              if (canEdit && b.open)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('admin-hire-booking-assign'),
                    onPressed: () => _assign(context, ref),
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: const Text('Give every day still to come to a driver'),
                  ),
                ),
              if (canEdit && b.open)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const ValueKey('admin-hire-booking-cancel'),
                    onPressed: () async {
                      if (!await confirm(context, 'Cancel this hire?',
                          'Every day still to come is cancelled and what was paid is refunded in full.',
                          ok: 'Cancel the hire')) {
                        return;
                      }
                      if (!context.mounted) return;
                      await runAdminAction(context, () => ref.read(hourlyHireRepositoryProvider).cancelBooking(b.id),
                          success: 'Hire cancelled and refunded');
                      ref.invalidate(adminHireBookingProvider(bookingId));
                    },
                    child: const Text('Cancel the hire'),
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }
}
