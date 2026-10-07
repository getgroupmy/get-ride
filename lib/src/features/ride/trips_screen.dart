import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';

final tripsProvider = FutureProvider.autoDispose<List<RideRequest>>(
  (ref) => ref.watch(rideRepositoryProvider).history(),
);

class TripsScreen extends ConsumerWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUserIdProvider);
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Trips')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(tripsProvider.future),
        child: AsyncView(
          value: ref.watch(tripsProvider),
          onRetry: () => ref.invalidate(tripsProvider),
          data: (trips) => trips.isEmpty
              ? ListView(children: const [
                  EmptyState(icon: Icons.receipt_long, title: 'No trips yet', message: 'Your rides will show up here.'),
                ])
              : ListView.builder(
                  itemCount: trips.length,
                  itemBuilder: (_, i) {
                    final r = trips[i];
                    final asDriver = r.partnerId == uid && r.riderId != uid;
                    return ResponsiveCenter(
                      maxWidth: 760,
                      child: Card(
                        child: ListTile(
                          leading: Icon(asDriver ? Icons.drive_eta : Icons.local_taxi),
                          title: Text('${r.pickupLabel} → ${r.dropLabel}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${formatDateTime(r.createdAt)} · ${r.status.label}'
                              '${asDriver ? ' · as driver' : ''}'),
                          trailing: Text(formatMoney(r.effectiveFare, r.currency)),
                          // A finished trip opens its receipt; one still under way, the live screen.
                          onTap: () => context.push(
                            r.status.isFinished
                                ? '/trips/${r.id}'
                                : (asDriver ? '/drive/trip/${r.id}' : '/ride/${r.id}'),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
