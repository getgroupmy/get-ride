// Admin › Settings › Office NAS › ID and face (migration 0320): the NAS
// reading MyKad and passports for the sign-in checks, the face match order
// (AWS, then the NAS's face server, then the in-browser check), today's
// work, and where "Needs a closer look" starts. The orders are changed here
// or in Dispatch › Accounts (the same fields). Scores only help the admin:
// nothing is approved or rejected automatically.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/signin_checks.dart';
import '../../../data/identity_repository.dart';
import '../../../widgets/common.dart';
import '../catalogue/catalogue_widgets.dart' show canEditPage;
import '../dispatch/identity_provider_fields.dart';
import '../../../core/office_nas.dart' show officeNasPage;

final nasIdFaceProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.watch(identityRepositoryProvider).nasIdFace(),
);

/// "2.1 s" from milliseconds; "–" when none.
String nasSeconds(Object? ms) => ms is num ? '${(ms / 1000).toStringAsFixed(1)} s' : '–';

/// The tab's rows, from admin_nas_id_face's answer (pure, for the tests).
List<(String, String)> nasIdFaceRows(Map<String, dynamic> m) {
  final c = IdentityConfig.fromJson(m['config']);
  final reader = m['reader'] is Map ? m['reader'] as Map : null;
  final reads = m['reads'] is Map ? m['reads'] as Map : const {};
  final faces = m['faces'] is Map ? m['faces'] as Map : const {};
  final done = (reads['done'] as num?)?.toInt() ?? 0;
  final passed = (reads['passed_on'] as num?)?.toInt() ?? 0;
  final closer = (m['closer'] as num?)?.toInt() ?? 0;
  final scored = [
    for (final (k, label) in const [('aws', 'AWS'), ('self_hosted', 'NAS'), ('browser', 'in-browser')])
      if ((faces[k] as num? ?? 0) > 0) '$label ${faces[k]}',
  ];
  return [
    ('ID card reading (MyKad, passport) for sign-in checks', orderText(c.idReaders, idReaderWords)),
    ('Face match order', orderText(c.faceOrder, faceOrderWords)),
    ('In-browser check', c.browserOn ? 'Runs while an admin has the queue open' : 'Off'),
    (
      'NAS document reader',
      reader == null
          ? 'Not connected'
          : '${reader['label'] ?? 'Office NAS'} · ${reader['online'] == true ? 'Online' : 'Offline'}',
    ),
    (
      'Read today',
      done == 0 && passed == 0
          ? 'None yet'
          : [
              '$done ${done == 1 ? 'card' : 'cards'} · ${nasSeconds(reads['avg_ms'])} each',
              if (passed > 0) '$passed passed on',
            ].join(' · '),
    ),
    ('Faces scored today', scored.isEmpty ? 'None yet' : scored.join(' · ')),
    (
      'Below ${c.faceLowScore}% match',
      'Marked "Needs a closer look"${closer > 0 ? ' · $closer waiting' : ''}',
    ),
  ];
}

class OfficeNasIdFace extends ConsumerWidget {
  const OfficeNasIdFace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canEdit = canEditPage(ref, officeNasPage);
    return AsyncView(
      value: ref.watch(nasIdFaceProvider),
      onRetry: () => ref.invalidate(nasIdFaceProvider),
      data: (m) => ResponsiveCenter(
        maxWidth: 900,
        child: ListView(
          key: const ValueKey('office-nas-id-face'),
          padding: const EdgeInsets.all(16),
          children: [
            for (final (k, v) in nasIdFaceRows(m))
              Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.dividerColor))),
                child: Row(
                  children: [
                    Expanded(child: Text(k, style: t.textTheme.bodyMedium)),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        v,
                        textAlign: TextAlign.end,
                        style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Text(
              'Photos come as 5-minute links, are read in memory and dropped. Only the fields asked for go back. '
              'Scores only help the admin decide; nothing is approved or rejected automatically.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Card(
              child: ExpansionTile(
                key: const ValueKey('office-nas-id-face-change'),
                title: const Text('Change the order'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [IdentityProviderFields(enabled: canEdit)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
