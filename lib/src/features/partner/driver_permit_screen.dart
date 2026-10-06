import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../admin/screens/people/people_data.dart';
import '../../core/driver_permit.dart';
import '../../data/vehicle_assignment_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/in_app_page.dart';

/// The signed-in partner's taxi driver permit, read from their uploads.
final driverPermitProvider = FutureProvider.autoDispose<DriverPermit>((ref) async {
  final partner = await ref.watch(partnerProvider.future);
  final profile = await ref.watch(profileProvider.future);
  Map<String, dynamic>? document;
  if (partner != null) {
    final people = ref.watch(peopleRepositoryProvider);
    final results = await Future.wait<Object>([people.requiredDocuments(), people.providerDocuments(partner.id)]);
    document = pickPermitDocument(
      results[0] as List<({String id, Map<String, dynamic> values})>,
      results[1] as List<Map<String, dynamic>>,
    );
  }
  return resolveDriverPermit(profile: profile?.raw, partner: partner?.raw, document: document);
});

/// The plate of the vehicle this partner is driving now, if any.
final currentPlateProvider = FutureProvider.autoDispose<String?>((ref) async {
  try {
    final list = await ref.watch(assignableVehiclesProvider.future);
    for (final v in list) {
      if (v.inUseByMe) return v.plate;
    }
  } catch (_) {}
  return null;
});

final _date = DateFormat('dd/MM/yyyy');

/// Taxi driver permit (Expo `partner-teksi` permit card): the permit's
/// details, its expiry and review state, and the checks a hire is held to
/// before the meter opens (IC matches the profile, not expired, vehicle
/// matches the permit).
class DriverPermitScreen extends ConsumerWidget {
  const DriverPermitScreen({super.key, this.today});

  /// Clock override for tests.
  final DateTime? today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver permit')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(driverPermitProvider);
          await ref.read(driverPermitProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ResponsiveCenter(
              maxWidth: 560,
              child: AsyncView(
                value: ref.watch(driverPermitProvider),
                onRetry: () => ref.invalidate(driverPermitProvider),
                data: (p) => _PermitBody(
                  permit: p,
                  plate: ref.watch(currentPlateProvider).value,
                  today: today ?? DateTime.now(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermitBody extends StatelessWidget {
  const _PermitBody({required this.permit, required this.plate, required this.today});
  final DriverPermit permit;
  final String? plate;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = permit;
    final days = daysToExpiry(p, today);
    final block = permitStartBlock(p, today: today, vehiclePlate: plate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!p.hasDocument)
          Card(
            color: t.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('No taxi driver permit uploaded'),
              subtitle: const Text('Upload your permit with your partner documents to show it here.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/drive/onboarding'),
            ),
          ),
        Card(
          key: const ValueKey('permit-card'),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: const Color(0xFFF5B301),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.local_taxi, color: Colors.black),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'TAXI DRIVER PERMIT · ${p.company}',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundImage: p.photoUrl == null ? null : NetworkImage(p.photoUrl!),
                      child: p.photoUrl == null ? const Icon(Icons.person, size: 40) : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name ?? '—', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                          if (p.driverType != null) Text(p.driverType!, style: t.textTheme.bodySmall),
                          const SizedBox(height: 8),
                          _field(t, 'IC no.', p.icNumber),
                          _field(t, 'Permit no.', p.permitNumber),
                          _field(t, 'Vehicle', p.vehiclePlate),
                          _field(t, 'Class', p.licenceClass),
                          _field(t, 'Valid from', p.issueDate == null ? null : _date.format(p.issueDate!)),
                          _field(t, 'Valid to', p.expiryDate == null ? null : _date.format(p.expiryDate!)),
                          _field(t, 'Address', p.address),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (p.documentStatus != null)
          Card(
            child: ListTile(
              leading: Icon(_statusIcon(p.documentStatus!), color: _statusColor(t, p.documentStatus!)),
              title: Text('Review: ${p.documentStatus}'),
              subtitle: p.documentName == null ? null : Text(p.documentName!),
            ),
          ),
        if (days != null && days < 0)
          _warning(t, Icons.event_busy, 'Expired ${-days} day${days == -1 ? '' : 's'} ago', error: true)
        else if (days != null && days <= 30)
          _warning(t, Icons.event, days == 0 ? 'Expires today' : 'Expires in $days day${days == 1 ? '' : 's'}'),
        if (block != null)
          _warning(t, Icons.block, permitBlockMessage(block, p, vehiclePlate: plate), error: true)
        else if (p.hasDocument)
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_outlined, color: Colors.green),
              title: const Text('Ready to drive'),
              subtitle: Text(plate == null ? 'No vehicle selected yet' : 'Driving $plate'),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (p.fileUrl != null)
              OutlinedButton.icon(
                icon: const Icon(Icons.description_outlined),
                label: const Text('View uploaded permit'),
                onPressed: () => openInApp(context, p.fileUrl!, title: 'Driver permit'),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Update documents'),
              onPressed: () => context.push('/drive/onboarding'),
            ),
            FilledButton.icon(
              key: const ValueKey('permit-open-meter'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.speed),
              label: const Text('Meter Digital'),
              onPressed: () => _openMeter(context, block),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openMeter(BuildContext context, PermitBlock? block) async {
    if (block == null) {
      context.push('/meter');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(switch (block) {
          PermitBlock.icMismatch => 'IC number mismatch',
          PermitBlock.expired => 'Permit expired',
          PermitBlock.plateMismatch => 'Vehicle mismatch',
        }),
        content: Text(permitBlockMessage(block, permit, vehiclePlate: plate)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () {
              Navigator.pop(c);
              context.go(block == PermitBlock.plateMismatch ? '/drive' : '/drive/onboarding');
            },
            child: Text(block == PermitBlock.plateMismatch ? 'Choose vehicle' : 'Update documents'),
          ),
        ],
      ),
    );
  }

  Widget _field(ThemeData t, String label, String? value) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label  ',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          TextSpan(text: value ?? '—', style: t.textTheme.bodyMedium),
        ],
      ),
    ),
  );

  Widget _warning(ThemeData t, IconData icon, String text, {bool error = false}) => Card(
    color: error ? t.colorScheme.errorContainer : t.colorScheme.tertiaryContainer,
    child: ListTile(leading: Icon(icon), title: Text(text)),
  );

  IconData _statusIcon(String s) => switch (s) {
    'Approved' => Icons.check_circle,
    'Rejected' || 'Expired' => Icons.cancel,
    _ => Icons.hourglass_top,
  };

  Color _statusColor(ThemeData t, String s) => switch (s) {
    'Approved' => Colors.green,
    'Rejected' || 'Expired' => t.colorScheme.error,
    _ => Colors.orange,
  };
}
