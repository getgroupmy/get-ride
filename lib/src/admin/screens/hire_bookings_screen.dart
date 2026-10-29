// Admin › Hire bookings (migrations 0327, 0328): every hire for several
// days, newest first, a page at a time — by status and package, searched
// by the rider's name or phone or the booking's id, and by the first day's
// date. A booking opens its view (hire_booking_view.dart): its days, giving
// every remaining day or one day to a driver, and cancelling, before day 1
// as well as after.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/hourly_hire.dart' show hireClock;
import '../../core/multi_day_hire.dart';
import '../../core/sms_limits.dart' show maskPhone;
import '../../data/hourly_hire_repository.dart';
import '../../data/live_tables.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../admin_access.dart';
import '../admin_providers.dart' show moduleAccessProvider;
import '../admin_registry.dart' show AdminScreenEntry;
import '../people_paging.dart' show PagedListBar;
import '../widgets/admin_widgets.dart';
import 'hire_booking_view.dart';

const hireBookingsPath = '/admin/m/hire-bookings';

final hireBookingsRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/hire-bookings', builder: (_, _) => const AdminHireBookingsScreen()),
];

/// Under Operations, next to Rides, with the Rides page's access.
const hireBookingsEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Operations',
    title: 'Hire bookings',
    subtitle: 'Daily, weekly and monthly hires: their days, drivers and payments',
    path: hireBookingsPath,
    pages: ['admin-rides'],
    icon: Icons.event_repeat_outlined,
  ),
];

/// What the list asks the server for.
typedef HireBookingsQuery = ({String status, String package, String query, String from, String to, int limit});

const hireBookingsPageSize = 50;

final adminHireBookingsProvider = FutureProvider.autoDispose
    .family<({List<AdminHireBooking> rows, int total}), HireBookingsQuery>((ref, q) {
  ref.watchAdminLive(hireBookingsTable);
  ref.watchAdminLive('scheduled_rides');
  return ref.watch(hourlyHireRepositoryProvider).adminBookings(
    status: q.status == 'all' ? null : q.status,
    package: q.package == 'all' ? null : q.package,
    query: q.query,
    from: parseIsoDate(q.from),
    to: parseIsoDate(q.to),
    limit: q.limit,
  );
});

const hireBookingStatusFilters = {
  'all': 'All',
  'booked': 'Booked',
  'assigned': 'Driver confirmed',
  'in_progress': 'In progress',
  'completed': 'Completed',
  'cancelled': 'Cancelled',
  'expired': 'Expired',
};

const hireBookingPackageFilters = {'all': 'Every package', 'daily': 'Daily', 'weekly': 'Weekly', 'monthly': 'Monthly'};

/// A row's second line: "Mon 2 Nov to Fri 13 Nov · 10 days · Saloon".
String adminHireBookingDates(AdminHireBooking b) => [
  '${hireDate(b.firstAt)}${b.lastAt == null || b.days <= 1 ? '' : ' to ${hireDate(b.lastAt!)}'}',
  b.days == 1 ? '1 day' : '${b.days} days',
  if (b.service.isNotEmpty) b.service,
].join(' · ');

/// "Rider Aina · +6012•••4567 · Driver Ali", or "No driver yet".
String adminHireBookingPeople(AdminHireBooking b) => [
  'Rider ${(b.riderName ?? '').trim().isEmpty ? 'unknown' : b.riderName!.trim()}',
  if ((b.riderPhone ?? '').trim().isNotEmpty) maskPhone(b.riderPhone!),
  (b.partnerName ?? '').trim().isEmpty ? 'No driver yet' : 'Driver ${b.partnerName!.trim()}',
].join(' · ');

class AdminHireBookingsScreen extends ConsumerStatefulWidget {
  const AdminHireBookingsScreen({super.key});

  @override
  ConsumerState<AdminHireBookingsScreen> createState() => _AdminHireBookingsScreenState();
}

class _AdminHireBookingsScreenState extends ConsumerState<AdminHireBookingsScreen> {
  String _status = 'all';
  String _package = 'all';
  String _query = '';
  int _limit = hireBookingsPageSize;
  final _from = TextEditingController();
  final _to = TextEditingController();

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  HireBookingsQuery get _q =>
      (status: _status, package: _package, query: _query, from: _from.text.trim(), to: _to.text.trim(), limit: _limit);

  void _set(VoidCallback f) => setState(() {
    f();
    _limit = hireBookingsPageSize;
  });

  void _open(AdminHireBooking b) {
    final canEdit = ref.read(moduleAccessProvider('rides')) == AccessLevel.edit;
    showAdminSheet<void>(
      context,
      title: '${b.title} · ${hireDate(b.firstAt)}, ${hireClock(b.firstAt)}',
      builder: (_) => AdminHireBookingView(bookingId: b.id, canEdit: canEdit),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final value = ref.watch(adminHireBookingsProvider(_q));
    return AdminPage(
      title: 'Hire bookings',
      module: 'rides',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(adminHireBookingsProvider(_q)),
        ),
      ],
      body: Column(children: [
        FilterBar(
          key: const ValueKey('hire-bookings-filters'),
          filters: hireBookingStatusFilters,
          selected: _status,
          onSelected: (s) => _set(() => _status = s),
          onSearch: (q) => _set(() => _query = q),
          hint: 'Search rider name, phone or booking id',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final e in hireBookingPackageFilters.entries)
              ChoiceChip(
                key: ValueKey('hire-bookings-package-${e.key}'),
                label: Text(e.value),
                selected: _package == e.key,
                onSelected: (_) => _set(() => _package = e.key),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 16, runSpacing: 8, children: [
            SizedBox(
              width: 320,
              child: DateBoxesField(
                key: const ValueKey('hire-bookings-from'),
                label: 'First day from',
                controller: _from,
                onChanged: (_) => _set(() {}),
              ),
            ),
            SizedBox(
              width: 320,
              child: DateBoxesField(
                key: const ValueKey('hire-bookings-to'),
                label: 'First day to',
                controller: _to,
                onChanged: (_) => _set(() {}),
              ),
            ),
          ]),
        ),
        Expanded(
          child: AsyncView(
            value: value,
            onRetry: () => ref.invalidate(adminHireBookingsProvider(_q)),
            data: (page) {
              if (page.rows.isEmpty) {
                return const EmptyState(
                  key: ValueKey('hire-bookings-empty'),
                  icon: Icons.event_repeat_outlined,
                  title: 'No hire bookings',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: page.rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final b = page.rows[i];
                  String money(double v) => formatMoney(v, b.currency ?? 'MYR');
                  return ListTile(
                    key: ValueKey('hire-bookings-row-${b.id}'),
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    title: Text(b.title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(adminHireBookingDates(b)),
                      Text(adminHireBookingPeople(b), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ]),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(money(b.price)),
                        Text(b.paymentLabel, style: t.textTheme.bodySmall),
                        StatusChip(b.status, label: hireBookingStatusFilters[b.status]),
                      ],
                    ),
                    onTap: () => _open(b),
                  );
                },
              );
            },
          ),
        ),
        if (value.value case final page? when page.total > page.rows.length)
          PagedListBar(
            count: '${page.rows.length} of ${page.total}',
            loading: value.isLoading,
            onLoadMore: () => setState(() => _limit += hireBookingsPageSize),
          ),
      ]),
    );
  }
}
