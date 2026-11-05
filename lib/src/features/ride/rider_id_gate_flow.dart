// Rider ID-verification gate UX (migrations 0342–0344): before a booking the
// admin's country rule may require the rider to verify a photo ID with a live
// selfie. [ensureRiderIdVerified] checks the rule and, when it applies, runs
// the capture + server face-match and returns whether the rider may now book.
// The server is the real enforcement (BEFORE INSERT triggers); this keeps the
// rider out of a failed booking and gives them the way through.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../admin/screens/people/people_data.dart' show docPhotoPickerProvider;
import '../../core/rider_id_gate.dart';
import '../../providers.dart';
import '../../widgets/common.dart' show showInfo, showError;
import '../../widgets/live_selfie.dart' show LiveSelfie, takeLiveSelfie;
import '../../widgets/live_selfie/on_device.dart' show readCardPhoto;
import '../../widgets/page_style_host.dart';
import '../../data/rider_id_gate_repository.dart';

/// The server's refusal when a booking needs ID verification first (0342).
bool isRiderIdRequired(Object error) => '$error'.contains('RIDER_ID_REQUIRED');

/// Whether the rider may book now. Returns true at once when no rule applies;
/// otherwise runs the verify flow and returns whether they got through.
Future<bool> ensureRiderIdVerified(BuildContext context, WidgetRef ref) async {
  final RiderIdGateRule rule;
  try {
    final config = await ref.read(riderIdGateConfigProvider.future);
    final profile = await ref.read(profileProvider.future);
    final blocked = riderIdGateBlocks(
      config: config,
      country: profile?.nationality,
      priorBookings: profile?.totalRides ?? 0,
      verified: profile?.isIdVerified ?? false,
    );
    if (!blocked) return true;
    rule = config.ruleFor(profile?.nationality) ?? RiderIdGateRule.standard;
  } catch (_) {
    // The rule or profile is unreadable (a transient error, a test without
    // these providers): don't block — the server trigger still enforces it.
    return true;
  }
  if (!context.mounted) return false;
  return _runVerify(context, ref, rule);
}

Future<bool> _runVerify(BuildContext context, WidgetRef ref, RiderIdGateRule rule) async {
  final go = await showAppDialog<bool>(
    id: 'ride.id-verify-intro',
    context: context,
    builder: (_) => _IdVerifyIntro(rule: rule),
  );
  if (go != true || !context.mounted) return false;

  // The ID photo. When saved photos aren't allowed, the camera only.
  Uint8List? idBytes;
  if (rule.allowPhoto) {
    final picked = await ref.read(docPhotoPickerProvider)(context);
    idBytes = picked?.bytes;
  } else {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85);
    idBytes = shot == null ? null : await shot.readAsBytes();
  }
  if (idBytes == null || !context.mounted) return false;

  // The live selfie (on a phone this cannot be a saved photo).
  final LiveSelfie? selfie = await takeLiveSelfie(context);
  if (selfie == null || !context.mounted) return false;

  // Read what we can off the ID (best-effort, on-device); the server keeps it
  // and fills the profile where empty when the match is strong.
  final card = await readCardPhoto(idBytes);
  final read = <String, dynamic>{
    if (card?.name != null) 'name': card!.name,
    if (card?.ic != null) 'ic': card!.ic,
    if (card?.expiry != null) 'expiry': _iso(card!.expiry!),
  };
  if (!context.mounted) return false;

  final docType = rule.idType == 'passport' ? 'passport' : 'national';
  final result = await _withWorking(context, () => ref.read(riderIdGateRepositoryProvider).riderVerify(
        docType: docType,
        idFront: idBytes!,
        selfie: selfie,
        read: read,
      ));
  if (!context.mounted) return false;

  if (result == null) {
    showError(context, "We couldn't verify your ID. Please try again.");
    return false;
  }
  if (result.verified) {
    showInfo(context, 'Identity verified. You can book now.');
    ref.invalidate(profileProvider);
    return true;
  }
  showInfo(context,
      'Thanks — your ID is being reviewed. You can book once it is approved, usually shortly.');
  return false;
}

/// Runs [task] behind a non-dismissible working dialog; null on any failure.
Future<({bool verified, bool pending})?> _withWorking(
  BuildContext context,
  Future<({bool verified, bool pending})> Function() task,
) async {
  final future = task();
  unawaited(showAppDialog<void>(
    id: 'ride.id-verify-working',
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          SizedBox(width: 16),
          Expanded(child: Text('Checking your ID…')),
        ]),
      ),
    ),
  ));
  ({bool verified, bool pending})? out;
  try {
    out = await future;
  } catch (_) {
    out = null;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  return out;
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _IdVerifyIntro extends StatelessWidget {
  const _IdVerifyIntro({required this.rule});
  final RiderIdGateRule rule;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final idWord = switch (rule.idType) {
      'national' => 'National ID',
      'passport' => 'Passport',
      _ => 'National ID or Passport',
    };
    return AlertDialog(
      key: const ValueKey('rider-id-verify-intro'),
      icon: Icon(Icons.verified_user_outlined, color: t.colorScheme.primary),
      title: const Text('Verify your ID to book'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('We need to confirm who you are before this booking. It takes a minute, once.',
              textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
          const SizedBox(height: 12),
          _line(context, Icons.badge_outlined, 'Scan your $idWord'),
          _line(context, Icons.face_retouching_natural_outlined, 'Take a quick selfie, matched to your ID'),
          if (!rule.allowPhoto)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Capture both live with the camera.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('rider-id-verify-start'),
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
