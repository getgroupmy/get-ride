// Partner registration identity gate (migration 0442). Before a partner
// registers, the admin's per-country rule may require them to verify their
// identity. [ensurePartnerIdVerified] decides whether verification is owed
// (the pure partnerIdGateBlocks), and when it is, runs the shared
// runIdVerification (GET eKYC when on, else the ID-photo + live-selfie
// fallback) — the same flow the rider gate uses, which sets profiles.id_verified
// and so lets the wizard skip the National ID and photo-liveness steps. The
// admin review of every partner is the real backstop.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/document_text.dart' show IdDocType;
import '../../core/partner_id_gate.dart';
import '../../core/rider_id_gate.dart' show RiderIdGateRule;
import '../../providers.dart';
import '../../widgets/page_style_host.dart';
import '../ride/rider_id_gate_flow.dart' show runIdVerification;

/// The admin's per-country partner gate (partner_id_gate_config RPC, 0442),
/// re-read when invalidated. Empty (off everywhere) on any error.
final partnerIdGateConfigProvider = FutureProvider<PartnerIdGateConfig>((ref) async {
  try {
    return PartnerIdGateConfig.fromJson(await ref.watch(supabaseProvider).rpc('partner_id_gate_config'));
  } catch (_) {
    return PartnerIdGateConfig.empty;
  }
});

/// Drop the cached partner gate after the server refused a booking/registration
/// despite the pre-check (the client's copy was stale).
void invalidatePartnerIdGate(WidgetRef ref) => ref.invalidate(partnerIdGateConfigProvider);

/// Whether the partner may go on with registration now.
///
/// Returns true at once when no verification is owed. Otherwise it runs the
/// shared ID + live-selfie verification and returns whether they may proceed:
/// an unverified partner must get through (verified, or pending an admin
/// review counts as not yet), while an already-verified partner sent back by
/// the citizen rule may proceed either way — the services step filters a
/// citizens-only service their ID can't take. A weak face match leaves the new
/// check pending an admin review.
///
/// [country] is the country the gate is read for (the partner's first service
/// country, else their nationality); [pickedCitizensOnly] whether a
/// citizens-only service is among the picks.
Future<bool> ensurePartnerIdVerified(
  BuildContext context,
  WidgetRef ref, {
  required String? country,
  required bool pickedCitizensOnly,
}) async {
  final PartnerIdGateConfig config;
  final bool verified;
  final IdDocType? idType;
  final String? nationality;
  try {
    config = await ref.read(partnerIdGateConfigProvider.future);
    final profile = await ref.read(profileProvider.future);
    verified = profile?.isIdVerified ?? false;
    idType = IdDocType.parse(profile?.raw['id_type']);
    nationality = profile?.nationality;
  } catch (_) {
    // Unreadable config or profile: don't trap the partner (the admin review
    // of the application is the backstop).
    return true;
  }

  final blocked = partnerIdGateBlocks(
    config: config,
    country: country,
    verified: verified,
    pickedCitizensOnly: pickedCitizensOnly,
    idType: idType,
    nationality: nationality,
  );
  if (!blocked) return true;
  if (!context.mounted) return false;

  final go = await showAppDialog<bool>(
    id: 'partner.id-verify-intro',
    context: context,
    // A verified partner only reaches here through the citizen rule, so the
    // prompt is about proving citizenship; an unverified one is verifying for
    // the first time.
    builder: (_) => _PartnerIdVerifyIntro(citizenReverify: verified),
  );
  // Declining: an already-verified partner may still go on (their citizens-only
  // pick is handled at the services step); an unverified one stays on the step.
  if (go != true) return verified;
  if (!context.mounted) return false;

  final result = await runIdVerification(
    context,
    ref,
    RiderIdGateRule.standard,
    verifiedMessage: 'Identity verified. You can continue your registration.',
    pendingMessage:
        'Thanks — your ID is being submitted for review. You can continue your registration now.',
  );
  // Once a check is submitted the partner may go on — the admin reviews the
  // whole application. An already-verified partner may go on regardless.
  return result.submitted || verified;
}

/// The intro before a partner verifies their identity at registration.
class _PartnerIdVerifyIntro extends StatelessWidget {
  const _PartnerIdVerifyIntro({required this.citizenReverify});

  /// A partner already verified, sent back by the citizen rule to prove
  /// citizenship with a national ID.
  final bool citizenReverify;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('partner-id-verify-intro'),
      icon: Icon(Icons.verified_user_outlined, color: t.colorScheme.primary),
      title: Text(citizenReverify ? 'Verify your citizen ID' : 'Verify your identity to register'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            citizenReverify
                ? 'A service you picked is for citizens only. Verify a national ID that shows you are a '
                    'citizen to take it on. It takes a minute.'
                : 'We need to confirm who you are before you register. It takes a minute, once.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          _line(context, Icons.badge_outlined, 'Scan your ID'),
          _line(context, Icons.face_retouching_natural_outlined, 'Take a quick selfie, matched to your ID'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('partner-id-verify-start'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Verify'),
        ),
      ],
    );
  }

  Widget _line(BuildContext context, IconData icon, String text) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Icon(icon, size: 20, color: t.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
      ]),
    );
  }
}
