// GET eKYC (migration 0439): the identity check run by our own eKYC server,
// its page shown inside the app (never the external browser). The server
// starts it (ekyc-start, which holds the API key), the page takes the ID's
// photos, a selfie and the head turns, and the result reaches the server by
// webhook (ekyc-webhook) as an ordinary identity check for the admin.
import 'dart:async';

import 'package:get_ekyc/get_ekyc.dart' show EkycOutcome, EkycResult, EkycWebViewFlow;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ekyc.dart';
import '../../data/ekyc_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/page_style_host.dart';

/// How a GET eKYC check ended: [sent] when the person finished it, and
/// [verified] when the server already verified them (riders, 0343).
typedef EkycCheckEnd = ({bool sent, bool verified});

/// Runs a GET eKYC check for [purpose] ('rider_gate' or 'first') and tells
/// the person how it went. Never throws.
Future<EkycCheckEnd> runEkycCheck(BuildContext context, WidgetRef ref, String purpose) async {
  const none = (sent: false, verified: false);
  final repo = ref.read(ekycRepositoryProvider);
  final ({String url, String sessionId}) started;
  try {
    started = await _working(context, 'Starting the identity check…', () => repo.start(purpose));
  } catch (e) {
    if (context.mounted) showError(context, ekycStartError(e));
    return none;
  }
  if (!context.mounted) return none;

  final lang = Localizations.localeOf(context).languageCode == 'ms' ? 'ms' : 'en';
  final result = await Navigator.of(context).push<EkycResult>(AppPageRoute(
    id: 'identity.ekyc',
    fullscreenDialog: true,
    builder: (_) => EkycWebViewFlow(hostedUrl: started.url, language: lang),
  ));
  final outcome = result?.outcome ?? EkycOutcome.cancelled;
  final sent = result?.sent ?? false;
  if (!context.mounted) return (sent: sent, verified: false);

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
  if (!context.mounted) return (sent: sent, verified: verified);
  final msg = ekycEndMessage(outcome, verified: verified);
  if (msg != null) {
    sent || verified ? showInfo(context, msg) : showError(context, msg);
  }
  return (sent: sent, verified: verified);
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
