// A hire for several days on the admin's ride details (migration 0327): the
// booking (its price, what was paid, its state) and every day with its
// pickup, status and whether a driver has it; cancelling it (free).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/hourly_hire.dart' show hireClock;
import '../../core/multi_day_hire.dart';
import '../../data/hourly_hire_repository.dart';
import '../../widgets/common.dart' show AsyncView;
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
                'Days': hireBookingSpan(b.firstAt, b.days, b.hoursPerDay),
                'Status': b.statusLabel,
                'Price': money(b.price),
                'Payment': b.paymentText(money),
                'Refunded': b.refundedAmount > 0 ? money(b.refundedAmount) : null,
                'Kept on cancelling': b.cancelFee > 0 ? money(b.cancelFee) : null,
                'Same driver': b.sameDriver ? (b.splitAt == null ? 'Yes' : 'Yes, split at the cut-off') : 'No',
              }),
              const SizedBox(height: 4),
              for (final d in v.days)
                Text(hireBookingDayLine(d, b.days), key: ValueKey('admin-hire-day-${d.day}'),
                    style: t.textTheme.bodySmall),
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
