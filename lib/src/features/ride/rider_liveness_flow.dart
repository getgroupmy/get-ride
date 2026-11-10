// Rider live-selfie (liveness) gate UX (migration 0401): the admin's country
// rule, or an approver's request, may require the rider to take a fresh live
// selfie before they can transact. [ensureLivenessOk] checks the requirement
// and, when it applies, runs the capture + submits it for approver verification.
// The server is the real enforcement (BEFORE INSERT triggers raise
// LIVENESS_REQUIRED); this keeps the rider out of a failed booking and gives
// them the way through.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/identity_repository.dart' show identityRepositoryProvider;
import '../../providers.dart' show supabaseProvider;
import '../../widgets/common.dart' show showInfo, showError;
import '../../widgets/live_selfie.dart' show LiveSelfie, takeLiveSelfie;
import '../../widgets/page_style_host.dart';

/// The server's refusal when a booking needs a fresh live selfie first (0401).
bool isLivenessRequired(Object error) => '$error'.contains('LIVENESS_REQUIRED');

/// Whether the rider may transact now. Returns true at once when no selfie is
/// owed; otherwise runs the capture + submit and returns false (they stay
/// blocked until an approver verifies it — the server trigger enforces that).
Future<bool> ensureLivenessOk(BuildContext context, WidgetRef ref) async {
  try {
    final required = (await ref.read(supabaseProvider).rpc('my_liveness_required')) == true;
    if (!required) return true;
  } catch (_) {
    // Unreadable (a transient error, a test without the RPC): don't block here;
    // the server trigger still enforces it.
    return true;
  }
  if (!context.mounted) return false;

  final go = await showAppDialog<bool>(
    id: 'ride.liveness-intro',
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Take a live selfie'),
      content: const Text(
          'Your profile needs a fresh live selfie before you can continue. It '
          'takes a few seconds and goes to an approver to verify.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('liveness-intro-go'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Take selfie')),
      ],
    ),
  );
  if (go != true || !context.mounted) return false;

  // On a phone this can only be a live capture, not a saved photo.
  final LiveSelfie? selfie = await takeLiveSelfie(context);
  if (selfie == null || !context.mounted) return false;

  try {
    await ref.read(identityRepositoryProvider).sendSelfie(selfie, recheck: true);
  } catch (_) {
    if (context.mounted) showError(context, "We couldn't send your selfie. Please try again.");
    return false;
  }
  if (context.mounted) {
    showInfo(context,
        'Thanks — your selfie is being reviewed. You can continue once it is approved.');
  }
  // Still blocked until an approver verifies it.
  return false;
}
