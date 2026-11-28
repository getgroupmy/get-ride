import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'api.dart';
import 'chip/bac.dart';
import 'chip/nfc_reader.dart';
import 'result.dart';
import 'strings.dart';

/// The hosted page inside the app (never the external browser). The page
/// tells the app when it is done through the `EkycBridge` channel; leaving
/// the GET.eKYC site is blocked, and a return link is caught as the result.
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
      onPermissionRequest: (req) => req.grant(), // camera for the GET.eKYC page only (navigation is locked to it)
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('EkycBridge', onMessageReceived: (m) {
        try {
          final msg = (jsonDecode(m.message) as Map).cast<String, dynamic>();
          if (msg['event'] == 'nfc_read') {
            _readChip(msg);
            return;
          }
          final r = EkycResult.fromBridge(msg);
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
    // ?nfc=1 tells the page this app can read a passport's chip
    var url = Uri.parse(widget.hostedUrl);
    if (await ChipReader.available()) {
      url = url.replace(queryParameters: {...url.queryParameters, 'nfc': '1'});
    }
    await c.loadRequest(url);
    if (mounted) setState(() => web = c);
  }

  /// The page asked for the chip: read it over NFC, send it to get.ekyc with
  /// the page's own link (the upload URL must be on the GET.eKYC site), and
  /// tell the page how it went.
  Future<void> _readChip(Map<String, dynamic> msg) async {
    final c = web;
    Future<void> reply(Map<String, Object?> r) async =>
        c?.runJavaScript('window.ekycChipDone && window.ekycChipDone(${jsonEncode(r)})');
    try {
      final keys = (msg['keys'] as Map).cast<String, dynamic>();
      final upload = Uri.parse(msg['upload_url'] as String);
      if (upload.origin != origin) throw ChipException('the page asked to send the chip elsewhere');
      final files = await ChipReader.read(
        documentNumber: keys['document_number'] as String,
        birth: keys['date_of_birth'] as String,
        expiry: keys['expiry_date'] as String,
        prompt: t('chipPrompt'),
        done: t('chipDone'),
      );
      final r = await http.put(upload, headers: {'Content-Type': 'application/json'}, body: jsonEncode(files.toJson()));
      if (r.statusCode != 200) throw ChipException('the chip could not be sent (${r.statusCode})');
      await reply({'ok': true, 'access': 'BAC'});
    } on ChipException catch (e) {
      await reply({'ok': false, 'error': e.message});
    } catch (e) {
      await reply({'ok': false, 'error': 'NFC is off or not allowed'});
    }
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
