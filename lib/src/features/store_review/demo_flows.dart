// The store review account's way into every feature (0333 follow-up): the
// "Try every feature" page (menu > How it works), and the helpers the
// booking screens call to play a demo booking on the phone. Each booking
// becomes a demo request (demoRidesProvider) that demo drivers answer with
// the shared offer motion, then the demo trip, pay, rate and receipt.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../core/booking_modules.dart';
import '../../core/demo/demo_script.dart';
import '../../core/demo_mode.dart' show demoPlaces, isDemoRideId;
import '../../core/format.dart';
import '../../core/scheduled_rides.dart' show ScheduledRide;
import '../../data/demo/demo_repositories.dart' show demoStoreProvider;
import '../../data/models.dart';
import '../../data/scheduled_ride_repository.dart' show myScheduledRidesProvider;
import '../../data/wallet_pay_repository.dart';
import '../../providers.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/page_style_host.dart';
import '../ride/courier_screen.dart' show openCourierPage;
import '../ride/demo_ride.dart' show DemoChip, demoRidesProvider;
import '../ride/freight_screen.dart' show openFreightPage;
import 'demo_contact.dart';
import 'demo_wallet.dart' show demoWalletProvider;

/// Opens the search of [booked] when it is a demo request (the store
/// review account's): true when it did.
bool openDemoRequest(BuildContext context, RideRequest? booked) {
  if (booked == null || !isDemoRideId(booked.id)) return false;
  GoRouter.maybeOf(context)?.push('/ride/${booked.id}');
  return true;
}

/// Books [row] (pickup and drop names and places, the fare) as a demo
/// request in [module] and opens its search, where demo drivers answer.
/// Nothing is written anywhere.
RideRequest playDemoBooking(BuildContext context, WidgetRef ref, Map<String, dynamic> row, {required String module}) {
  final a = demoPlaces[1], b = demoPlaces[0];
  final pLat = (row['pickup_lat'] as num?)?.toDouble() ?? a.$3;
  final pLng = (row['pickup_lng'] as num?)?.toDouble() ?? a.$4;
  final req = ref.read(demoRidesProvider.notifier).create({
    'rider_id': ref.read(currentUserIdProvider),
    'service': 'Car',
    'payment_mode': 'Cash',
    'currency': AppConfig.currency,
    'offer_me': true,
    ...row,
    'pickup_name': row['pickup_name'] ?? a.$1,
    'pickup_lat': pLat,
    'pickup_lng': pLng,
    'drop_name': row['drop_name'] ?? b.$1,
    'drop_lat': (row['drop_lat'] as num?)?.toDouble() ?? (row['pickup_lat'] == null ? b.$3 : pLat + 0.03),
    'drop_lng': (row['drop_lng'] as num?)?.toDouble() ?? (row['pickup_lng'] == null ? b.$4 : pLng + 0.02),
    'fare': row['fare'] ?? 25.0,
    'demo_module': module,
  });
  GoRouter.maybeOf(context)?.push('/ride/${req.id}');
  return req;
}

/// A demo booking for later (the store review account's) played out now:
/// marked released, and its demo request opened.
void runDemoScheduled(BuildContext context, WidgetRef ref, ScheduledRide ride) {
  final row = ref.read(demoStoreProvider).scheduled[ride.id];
  if (row == null) return;
  final request = row['request'] is Map ? Map<String, dynamic>.from(row['request'] as Map) : row;
  final module = row['hire_package'] != null || request['hire_hours'] != null ? familyModuleHire : familyModuleScheduled;
  final req = playDemoBooking(context, ref, {
    for (final k in const ['pickup_name', 'pickup_address', 'pickup_lat', 'pickup_lng', 'drop_name', 'drop_address',
      'drop_lat', 'drop_lng', 'fare', 'currency', 'service', 'payment_mode', 'booked_for_name'])
      if (request[k] != null) k: request[k],
  }, module: module);
  ref.read(demoStoreProvider.notifier).putScheduled({...row, 'status': 'released', 'ride_id': req.id});
  ref.invalidate(myScheduledRidesProvider);
}

/// A demo trip in [module] between two well-known places, for a module the
/// region has switched off or to try it in one tap.
RideRequest playQuickDemo(BuildContext context, WidgetRef ref, String module) {
  final a = demoPlaces[1], b = module == familyModuleCityToCity ? demoPlaces[6] : demoPlaces[0];
  final fare = switch (module) {
    familyModuleCityToCity => 120.0,
    familyModuleFreight => 90.0,
    familyModuleHire => 60.0,
    familyModuleCourier => 12.0,
    _ => 18.0,
  };
  return playDemoBooking(context, ref, {
    'pickup_name': a.$1,
    'pickup_address': a.$2,
    'pickup_lat': a.$3,
    'pickup_lng': a.$4,
    'drop_name': b.$1,
    'drop_address': b.$2,
    'drop_lat': b.$3,
    'drop_lng': b.$4,
    'fare': fare,
  }, module: module);
}

/// Pay a demo shop by QR from the demo GET.wallet (no camera needed: the
/// code is "scanned" for you).
Future<void> showDemoQrPay(BuildContext context, WidgetRef ref) async {
  const amount = 12.5;
  final pay = await showAppDialog<bool>(
    id: 'review.demo-qr-pay',
    context: context,
    builder: (c) => AlertDialog(
      key: const ValueKey('demo-qr-pay'),
      title: const Row(children: [Expanded(child: Text('Pay by QR')), DemoChip()]),
      content: Text(
        'Scanned: Kedai Demo (a demo shop).\nAmount: ${formatMoney(amount, AppConfig.currency)}\n\n'
        'Paid from your demo GET.wallet. No real money moves.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('demo-qr-pay-confirm'),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Pay'),
        ),
      ],
    ),
  );
  if (pay != true || !context.mounted) return;
  try {
    await ref.read(walletPayRepositoryProvider).pay(amount, note: 'Demo QR: Kedai Demo');
    if (!context.mounted) return;
    await showAppNotice(
      id: 'notice.review-demo-qr',
      context: context,
      title: 'Paid (demo)',
      message: 'You paid ${formatMoney(amount, AppConfig.currency)} to Kedai Demo. New demo GET.wallet balance: '
          '${formatMoney(ref.read(demoWalletProvider).wallet, AppConfig.currency)}.',
    );
  } catch (_) {
    if (!context.mounted) return;
    await showAppNotice(
      id: 'notice.review-demo-qr',
      context: context,
      message: 'Not enough in the demo GET.wallet. Top it up in Wallet first.',
      kind: NoticeKind.error,
    );
  }
}

/// Opens the "Try every feature" page.
Future<void> openDemoFeatures(BuildContext context) => Navigator.of(context).push<void>(
  AppPageRoute(id: 'review.features', builder: (_) => const DemoFeaturesScreen()),
);

/// Every feature, how to try it in the demo, and a button to open it.
class DemoFeaturesScreen extends ConsumerWidget {
  const DemoFeaturesScreen({super.key});

  static const _quick = {
    familyModuleRide,
    familyModuleHire,
    familyModuleCityToCity,
    familyModuleCourier,
    familyModuleFreight,
  };

  Future<void> _open(BuildContext context, WidgetRef ref, DemoFeature f) async {
    switch (f.key) {
      case familyModuleCourier:
        await openCourierPage(context);
      case familyModuleFreight:
        await openFreightPage(context);
      case 'chat':
        await openDemoChat(context, peer: DemoPeer.driver, name: 'Mellier');
      case 'call':
        await openDemoCall(context, name: 'Mellier');
      case 'sos':
        await showDemoSos(context, ref);
      default:
        final route = f.route;
        if (route != null) GoRouter.maybeOf(context)?.go(route);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    Widget card(DemoFeature f) => Card(
      key: ValueKey('demo-feature-${f.key}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(f.title, style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(f.how, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
            if (_quick.contains(f.key))
              TextButton(
                key: ValueKey('demo-quick-${f.key}'),
                onPressed: () => playQuickDemo(context, ref, f.key),
                child: const Text('Quick demo trip'),
              ),
            if (f.key == 'wallet')
              TextButton(
                key: const ValueKey('demo-qr-pay-open'),
                onPressed: () => showDemoQrPay(context, ref),
                child: const Text('Pay by QR'),
              ),
            TextButton(
              key: ValueKey('demo-open-${f.key}'),
              onPressed: () => _open(context, ref, f),
              child: const Text('Open'),
            ),
          ]),
        ]),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text('Try every feature', overflow: TextOverflow.ellipsis)),
          SizedBox(width: 8),
          DemoChip(),
        ]),
      ),
      body: Column(children: [
        const DemoBanner(),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(12), children: [
            Text('As a passenger', style: t.textTheme.titleSmall),
            for (final f in demoFeaturesFor(DemoSide.passenger)) card(f),
            const SizedBox(height: 12),
            Text('As a driver', style: t.textTheme.titleSmall),
            for (final f in demoFeaturesFor(DemoSide.driver)) card(f),
          ]),
        ),
      ]),
    );
  }
}
