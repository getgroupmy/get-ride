// GET.eKYC (migration 0439): the identity check run by our own eKYC server,
// its page shown inside the app (never the external browser). The server
// starts it (ekyc-start, which holds the API key), the page takes the ID's
// photos, a selfie and the head turns, and the result reaches the server by
// webhook (ekyc-webhook) as an ordinary identity check for the admin.
import 'dart:async';

import 'package:get_ekyc/get_ekyc.dart' show EkycOutcome, EkycResult, EkycWebViewFlow;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ekyc.dart';
import '../../data/ekyc_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/in_app_page.dart' show webViewSupported;
import '../../widgets/page_style_host.dart';

/// How a GET.eKYC check ended: [sent] when the person finished it, [verified]
/// when the server already verified them (riders, 0343), and [unavailable]
/// when the check could not START — the signal for a caller to fall back to
/// the next validator (the ID-photo + live-selfie face match).
typedef EkycCheckEnd = ({bool sent, bool verified, bool unavailable});

/// Runs a GET.eKYC check for [purpose] ('rider_gate' or 'first') and tells
/// the person how it went. Never throws. When [canFallBack] is set, a failure
/// to start the check is left silent and reported only through [unavailable],
/// so the caller can fall through to its own flow; otherwise the start error
/// is shown to the person as before.
Future<EkycCheckEnd> runEkycCheck(BuildContext context, WidgetRef ref, String purpose,
    {bool canFallBack = false}) async {
  const none = (sent: false, verified: false, unavailable: false);
  final repo = ref.read(ekycRepositoryProvider);
  final ({String url, String sessionId}) started;
  try {
    started = await _working(context, 'Starting the identity check…', () => repo.start(purpose));
  } catch (e) {
    if (context.mounted && !canFallBack) showError(context, ekycStartError(e));
    return (sent: false, verified: false, unavailable: true);
  }
  if (!context.mounted) return none;

  final lang = Localizations.localeOf(context).languageCode == 'ms' ? 'ms' : 'en';
  // On Android and iOS the page runs inside the app. The web and desktop
  // apps can't show a page inside, so it opens in a new tab and the person
  // taps Done when it says so; the server's record says whether it was sent.
  final EkycResult? result = webViewSupported
      ? await Navigator.of(context).push<EkycResult>(AppPageRoute(
          id: 'identity.ekyc',
          fullscreenDialog: true,
          builder: (_) => EkycWebViewFlow(hostedUrl: started.url, language: lang),
        ))
      : await _inBrowserTab(context, repo, started);
  final outcome = result?.outcome ?? EkycOutcome.cancelled;
  final sent = result?.sent ?? false;
  if (!context.mounted) return (sent: sent, verified: false, unavailable: false);

  var verified = false;
  if (sent) {
    // The webhook usually lands within seconds of the page closing.
    final state = await _working(context, 'Checking your ID…', () => repo.waitForResult(started.sessionId));
    if (state == 'completed' && purpose == 'rider_gate') {
      ref.invalidate(profileProvider);
      try {
        verified = (await ref.read(profileProvider.future))?.isIdVerified ?? false;
      } catch (_) {}
    }
  }
  if (!context.mounted) return (sent: sent, verified: verified, unavailable: false);
  final msg = ekycEndMessage(outcome, verified: verified);
  if (msg != null) {
    sent || verified ? showInfo(context, msg) : showError(context, msg);
  }
  return (sent: sent, verified: verified, unavailable: false);
}

/// The web and desktop apps: the check's page in a new browser tab, then the
/// person says they are done and the server's record of the session decides.
Future<EkycResult?> _inBrowserTab(
  BuildContext context,
  EkycRepository repo,
  ({String url, String sessionId}) started,
) async {
  var opened = false;
  try {
    opened = await launchUrl(Uri.parse(started.url), webOnlyWindowName: '_blank');
  } catch (_) {}
  if (!context.mounted) return null;
  if (!opened) {
    showError(context, "The identity check page didn't open. Allow pop-ups for this site and try again.");
    return null;
  }
  final done = await showAppDialog<bool>(
    id: 'identity.ekyc-browser',
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.open_in_new),
      title: const Text('Finish in the new tab'),
      content: const Text('Complete the identity check in the tab that just opened. When it says "All done", '
          'come back here and tap Done.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Done')),
      ],
    ),
  );
  if (done != true || !context.mounted) return const EkycResult(EkycOutcome.cancelled);
  final state = await _working(context, 'Checking your ID…',
      () => repo.waitForResult(started.sessionId, timeout: const Duration(seconds: 15)));
  return EkycResult(state == 'completed' ? EkycOutcome.submitted : EkycOutcome.cancelled);
}

/// Runs [task] behind a non-dismissible working dialog and returns its value.
Future<T> _working<T>(BuildContext context, String text, Future<T> Function() task) async {
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  unawaited(showAppDialog<void>(
    id: 'identity.ekyc-working',
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ]),
      ),
    ),
  ).whenComplete(() => open = false));
  try {
    return await task();
  } finally {
    if (open && nav.mounted) nav.pop();
  }
}
