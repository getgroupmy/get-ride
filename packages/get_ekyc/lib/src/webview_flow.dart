import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'api.dart';
import 'result.dart';
import 'strings.dart';

/// The hosted page inside the app (never the external browser). The page
/// tells the app when it is done through the `EkycBridge` channel; leaving
/// the GET eKYC site is blocked, and a return link is caught as the result.
class EkycWebViewFlow extends StatefulWidget {
  const EkycWebViewFlow({super.key, required this.hostedUrl, this.language = 'en'});
  final String hostedUrl;
  final String language;

  @override
  State<EkycWebViewFlow> createState() => _EkycWebViewFlowState();
}

class _EkycWebViewFlowState extends State<EkycWebViewFlow> {
  WebViewController? web;
  bool done = false;
  late final String origin = EkycApi(widget.hostedUrl).origin;
  late final EkycStrings t = EkycStrings(widget.language);

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  // The OS camera permission must be granted to the app before a WebView may
  // use the camera; opening the camera plugin once asks for it.
  Future<void> _askCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) return;
      final c = CameraController(cams.first, ResolutionPreset.low, enableAudio: false);
      await c.initialize();
      await c.dispose();
    } catch (_) {
      // denied: the page offers taking photos with the camera app instead
    }
  }

  Future<void> _setUp() async {
    await _askCamera();
    final params = WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(allowsInlineMediaPlayback: true, mediaTypesRequiringUserAction: const {})
        : const PlatformWebViewControllerCreationParams();
    final c = WebViewController.fromPlatformCreationParams(
      params,
      onPermissionRequest: (req) => req.grant(), // camera for the GET eKYC page only (navigation is locked to it)
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('EkycBridge', onMessageReceived: (m) {
        try {
          final r = EkycResult.fromBridge((jsonDecode(m.message) as Map).cast<String, dynamic>());
          if (r != null) _finish(r);
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: (req) {
        final uri = Uri.tryParse(req.url);
        if (uri == null) return NavigationDecision.prevent;
        final ret = EkycResult.fromReturnUri(uri);
        if (ret != null && uri.origin != origin) {
          _finish(ret);
          return NavigationDecision.prevent;
        }
        return uri.origin == origin ? NavigationDecision.navigate : NavigationDecision.prevent;
      }));
    await c.loadRequest(Uri.parse(widget.hostedUrl));
    if (mounted) setState(() => web = c);
  }

  void _finish(EkycResult r) {
    if (done || !mounted) return;
    done = true;
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(const EkycResult(EkycOutcome.cancelled));
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('title')),
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () => _finish(const EkycResult(EkycOutcome.cancelled))),
        ),
        body: web == null ? const Center(child: CircularProgressIndicator()) : WebViewWidget(controller: web!),
      ),
    );
  }
}
