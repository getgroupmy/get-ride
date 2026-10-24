// Owner rule (0288): a document with the person's photo on it (the National
// ID, a Kad Pemandu, a driving licence, any Required Document marked "Has
// the person's photo") is matched against a live selfie. On a phone the
// person must have one (the blink or turn check passed) before such a
// document is sent: if not, a modal asks them to take it now. Where the
// check can't run (the web, desktops) the document is sent anyway and the
// server records the match as not checked, flagged for the admin.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/identity_repository.dart';
import 'common.dart';
import 'live_selfie.dart';
import 'page_style_host.dart';

/// Whether the document may be sent now.
typedef LiveSelfieGate = Future<bool> Function(BuildContext context);

final liveSelfieGateProvider = Provider<LiveSelfieGate>(
  (ref) => (context) => ensureLiveSelfie(context, ref.read(identityRepositoryProvider)),
);

/// True once the person has a live selfie on record, taking one first when
/// needed (a modal explains why); false when they back out. [onPhone] and
/// [takeSelfie] are for tests.
Future<bool> ensureLiveSelfie(
  BuildContext context,
  IdentityRepository identity, {
  bool? onPhone,
  Future<LiveSelfie?> Function(BuildContext context)? takeSelfie,
}) async {
  if (!(onPhone ?? liveSelfieOnPhone)) return true;
  if (await identity.liveSelfieOk()) return true;
  if (!context.mounted) return false;
  final go = await showAppDialog<bool>(
    id: 'documents.live-selfie-needed',
    context: context,
    builder: (c) => AlertDialog(
      key: const ValueKey('live-selfie-needed'),
      icon: const Icon(Icons.face),
      title: const Text('Take a live selfie first'),
      content: const Text(
        'This document has your photo on it, so we match it with a live selfie. Hold the phone at eye level; '
        'the photo is taken when you blink or turn your head.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('live-selfie-take'),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Take selfie'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return false;
  final selfie = await (takeSelfie ?? takeLiveSelfie)(context);
  if (selfie == null || !selfie.live || !context.mounted) return false;
  try {
    await identity.recordLiveSelfie(selfie);
    return true;
  } catch (e) {
    if (context.mounted) await showErrorNotice(context, e);
    return false;
  }
}
