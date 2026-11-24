/// GET eKYC for Flutter (iOS and Android).
///
/// Your server creates the verification with its API key and gives the app
/// only the `hosted_url`. Then, in the app:
///
/// ```dart
/// final r = await GetEkyc.start(context, hostedUrl: url);              // native screens
/// final r = await GetEkyc.start(context, hostedUrl: url, mode: EkycMode.webView); // hosted page in the app
/// await GetEkyc.openInBrowser(url);  // browser, back through your redirect_url app link
/// ```
///
/// [EkycResult] says how the session ended. The decision itself reaches your
/// server by the signed webhook: act on that, not on the app's result.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/native_flow.dart';
import 'src/result.dart';
import 'src/webview_flow.dart';

export 'src/api.dart' show EkycApi, EkycApiException, EkycSessionInfo, EkycDocument, EkycStatus;
export 'src/native_flow.dart' show EkycNativeFlow;
export 'src/pose.dart' show PoseSteps;
export 'src/result.dart';
export 'src/webview_flow.dart' show EkycWebViewFlow;

enum EkycMode {
  /// Native screens in the app: camera, guided head turns with on-device face
  /// tracking. Best experience; screen changes come with SDK updates.
  native,

  /// GET eKYC's hosted page inside the app (WebView). Every change on the
  /// server reaches users at once, with no app update.
  webView,
}

class GetEkyc {
  GetEkyc._();

  /// Runs the verification inside the app and returns how it ended.
  /// [language]: 'en' or 'ms'.
  static Future<EkycResult> start(
    BuildContext context, {
    required String hostedUrl,
    EkycMode mode = EkycMode.native,
    String language = 'en',
  }) async {
    final page = switch (mode) {
      EkycMode.native => EkycNativeFlow(hostedUrl: hostedUrl, language: language),
      EkycMode.webView => EkycWebViewFlow(hostedUrl: hostedUrl, language: language),
    };
    final r = await Navigator.of(context).push<EkycResult>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => page),
    );
    return r ?? const EkycResult(EkycOutcome.cancelled);
  }

  /// Opens the hosted page in the phone's browser. The user comes back through
  /// the `redirect_url` your server gave (e.g. getride://ekyc-done); read it
  /// with [EkycResult.fromReturnUri] in your app-link handler.
  static Future<bool> openInBrowser(String hostedUrl) =>
      launchUrl(Uri.parse(hostedUrl), mode: LaunchMode.externalApplication);
}
