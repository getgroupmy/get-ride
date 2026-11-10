// Rider live-selfie (liveness) gate UX (migration 0401): the admin's country
// rule, or an approver's request, may require the rider to take a fresh live
// selfie before they can transact. [ensureLivenessOk] checks the requirement
// and, when it applies, runs the capture + submits it for approver verification;
// [promptLivenessOnLaunch] nudges a rider who still owes one at app launch. The
// server is the real enforcement (BEFORE INSERT triggers raise LIVENESS_REQUIRED).
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

enum _Liveness { ok, pending, capture }

/// Reads whether the rider owes a live selfie: ok (none owed), pending (already
/// submitted, awaiting verification), or capture (must take one). Never throws —
/// an unreadable state is treated as ok (the server trigger still enforces).
Future<_Liveness> _state(WidgetRef ref) async {
  try {
    final db = ref.read(supabaseProvider);
    final required = (await db.rpc('my_liveness_required')) == true;
    if (!required) return _Liveness.ok;
    final pending = (await db.rpc('my_liveness_pending')) == true;
    return pending ? _Liveness.pending : _Liveness.capture;
  } catch (_) {
    return _Liveness.ok;
  }
}

/// Whether the rider may transact now. true when none is owed; otherwise runs
/// the capture (or says it is under review) and returns false — they stay
/// blocked until an approver verifies it.
Future<bool> ensureLivenessOk(BuildContext context, WidgetRef ref) async {
  switch (await _state(ref)) {
    case _Liveness.ok:
      return true;
    case _Liveness.pending:
      if (context.mounted) {
        showInfo(context, 'Your live selfie is being reviewed. You can continue once it is approved.');
      }
      return false;
    case _Liveness.capture:
      if (!context.mounted) return false;
      return _capture(context, ref);
  }
}

/// At app launch, prompt a rider who must take a live selfie — but not one who
/// already submitted and is waiting to be verified.
Future<void> promptLivenessOnLaunch(BuildContext context, WidgetRef ref) async {
  if (await _state(ref) == _Liveness.capture && context.mounted) {
    await _capture(context, ref);
  }
}

Future<bool> _capture(BuildContext context, WidgetRef ref) async {
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
