import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Dials [number] with the phone app. Where nothing can place a call (a
/// desktop browser, a tablet without a SIM) the number is shown with a Copy
/// action instead of the tap doing nothing. [launcher] is for tests.
Future<void> callNumber(
  BuildContext context,
  String number, {
  Future<bool> Function(Uri uri)? launcher,
  bool? dials,
}) async {
  // A desktop browser "opens" tel: without anything happening: the number
  // and Copy straight away there.
  if (!(dials ?? canDialHere())) {
    showNumberToCopy(context, number);
    return;
  }
  final cleaned = number.replaceAll(RegExp(r'[^+\d]'), '');
  var ok = false;
  try {
    ok = await (launcher ?? launchUrl)(Uri(scheme: 'tel', path: cleaned));
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) showNumberToCopy(context, number);
}

/// Whether a tel: link can place a call here: the apps and a phone's
/// browser. A desktop browser hands tel: to whatever claims it, often
/// nothing, and still reports success. [web] and [platform] are for tests.
bool canDialHere({bool web = kIsWeb, TargetPlatform? platform}) {
  if (!web) return true;
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.android || p == TargetPlatform.iOS;
}

/// "Can't call from here" with the number and a Copy action.
void showNumberToCopy(BuildContext context, String number) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('call-fallback'),
        content: Text("Can't place a call here. Call $number"),
        action: SnackBarAction(
          label: 'Copy',
          onPressed: () => Clipboard.setData(ClipboardData(text: number)),
        ),
      ),
    );
}
