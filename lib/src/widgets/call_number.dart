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
}) async {
  final cleaned = number.replaceAll(RegExp(r'[^+\d]'), '');
  var ok = false;
  try {
    ok = await (launcher ?? launchUrl)(Uri(scheme: 'tel', path: cleaned));
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) showNumberToCopy(context, number);
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
