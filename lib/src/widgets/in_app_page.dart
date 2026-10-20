import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config.dart';
import '../core/backend_network.dart' show backendAllowedDomain;
import '../core/link_view.dart';
import '../data/storage_links.dart';
import 'page_style_host.dart';

/// Opens [url] inside the app on a screen with a back button: a web page in a
/// web view, a picture full screen with pinch-zoom, a PDF page by page. A
/// call, text, email or another app's link is still handed to that app.
///
/// The web view exists on Android and iOS only; the website (already a
/// browser) opens a page in a new tab, and desktop builds in the browser.
Future<void> openInApp(BuildContext context, String link, {String? title}) =>
    _open(context, link, title: title, stored: false);

/// [openInApp] for a file somebody else's record points at (a document, an
/// ID image, a chat video, a recording): only a file from the app's own
/// storage opens ([isOwnStorageLink]), and a page shows without scripts.
Future<void> openStoredFile(BuildContext context, String link, {String? title}) =>
    _open(context, link, title: title, stored: true);

Future<void> _open(BuildContext context, String link, {String? title, required bool stored}) async {
  // A file in a private document bucket opens through a signed link.
  final url = await signedStorageUrl(link);
  if (!context.mounted) return;
  final uri = Uri.tryParse(url.trim());
  if (uri == null) {
    _couldNotOpen(context, url);
    return;
  }
  if (stored && !isOwnStorageLink(uri, projectUrl: AppConfig.supabaseUrl, allowedDomain: backendAllowedDomain)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('This file is not stored by GET.ride, so it was not opened.')),
    );
    return;
  }
  final name = title ?? linkTitle(uri);
  final Widget? page = switch (linkViewFor(uri)) {
    LinkView.image => ImageViewerScreen(url: url, title: name),
    LinkView.pdf => PdfViewerScreen(url: url, title: name),
    LinkView.web => webViewSupported ? WebPageScreen(url: url, title: name, javascript: !stored) : null,
    LinkView.external => null,
  };
  if (page != null) {
    await Navigator.of(context, rootNavigator: true).push(AppPageRoute<void>(id: 'in-app.open-in-app', builder: (_) => page));
    return;
  }
  var ok = false;
  try {
    ok = await launchUrl(
      uri,
      mode: linkViewFor(uri) == LinkView.external ? LaunchMode.externalApplication : LaunchMode.platformDefault,
    );
  } catch (_) {}
  if (!ok && context.mounted) _couldNotOpen(context, url);
}

/// A payment provider's checkout: its hosted page ([url]) or, for a provider
/// whose page is opened by posting a form ([form], iPay88), that form. Inside
/// the app on Android and iOS, closing by itself once the page reaches one
/// of [closeOn] (the `payments` function's return pages); elsewhere in the
/// browser. Returns when the payer is back.
Future<void> openPaymentPage(
  BuildContext context, {
  String? url,
  ({String action, Map<String, String> fields})? form,
  List<String> closeOn = const [],
  String title = 'Payment',
}) async {
  if (webViewSupported) {
    await Navigator.of(context, rootNavigator: true).push(AppPageRoute<void>(
      id: 'in-app.payment-page',
      builder: (_) => WebPageScreen(
        url: url ?? form!.action,
        title: title,
        html: form == null ? null : paymentFormHtml(form.action, form.fields),
        closeOn: closeOn,
      ),
    ));
    return;
  }
  if (url == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('This payment method opens in the GET.ride phone app.')),
    );
    return;
  }
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && context.mounted) _couldNotOpen(context, url);
}

/// A page that posts [fields] to [action] as soon as it loads.
String paymentFormHtml(String action, Map<String, String> fields) {
  String esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  final inputs = fields.entries.map((e) => '<input type="hidden" name="${esc(e.key)}" value="${esc(e.value)}">').join();
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1"></head>'
      '<body onload="document.forms[0].submit()"><p style="font-family:sans-serif">Opening the payment page…</p>'
      '<form method="post" action="${esc(action)}">$inputs</form></body></html>';
}

void _couldNotOpen(BuildContext context, String url) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not open $url')));

/// Whether this build can show a web page inside the app.
bool get webViewSupported =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// A web page inside the app. Back steps back through the page's own history
/// first, then leaves the screen.
class WebPageScreen extends StatefulWidget {
  const WebPageScreen({
    super.key,
    required this.url,
    required this.title,
    this.javascript = true,
    this.html,
    this.closeOn = const [],
  });

  final String url;
  final String title;

  /// A page to show instead of loading [url] (a payment form that posts itself).
  final String? html;

  /// The screen closes once a page whose address starts with one of these
  /// has loaded (a payment's return page).
  final List<String> closeOn;

  /// Off for a file from somebody else's record: it is shown, not run.
  final bool javascript;

  @override
  State<WebPageScreen> createState() => _WebPageScreenState();
}

class _WebPageScreenState extends State<WebPageScreen> {
  late final WebViewController _web;
  int _progress = 0;

  /// Whether the page has its own history to step back through. Only then
  /// is the screen held to go back in it; otherwise iOS's edge swipe (and
  /// Back) leave the screen as on any other page.
  bool _canGoBack = false;

  Future<void> _syncCanGoBack() async {
    final can = await _web.canGoBack();
    if (mounted && can != _canGoBack) setState(() => _canGoBack = can);
  }

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(widget.javascript ? JavaScriptMode.unrestricted : JavaScriptMode.disabled)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageFinished: (url) {
            if (widget.closeOn.any((p) => p.isNotEmpty && url.startsWith(p))) {
              if (mounted && !_closed) {
                _closed = true;
                Navigator.of(context).pop();
              }
              return;
            }
            unawaited(_syncCanGoBack());
          },
          onUrlChange: (_) => unawaited(_syncCanGoBack()),
          // A link on the page to a call, an email or another app goes to
          // that app; everything on the web stays here.
          onNavigationRequest: (req) {
            final uri = Uri.tryParse(req.url);
            if (uri != null && linkViewFor(uri) == LinkView.external) {
              unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
    if (widget.html != null) {
      _web.loadHtmlString(widget.html!);
    } else {
      _web.loadRequest(Uri.parse(widget.url));
    }
  }

  /// Closed itself on a return page (once: the page may finish twice).
  bool _closed = false;

  Future<void> _back() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
      await _syncCanGoBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => Navigator.of(context).pop()),
          title: Text(widget.title),
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100, minHeight: 2),
                )
              : null,
        ),
        body: WebViewWidget(controller: _web),
      ),
    );
  }
}

/// A picture inside the app, full screen with pinch-zoom.
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url);
    final data = uri?.scheme == 'data' ? uri!.data?.contentAsBytes() : null;
    Widget failed(BuildContext _, Object _, StackTrace? _) => const Center(
      child: Text('This picture could not be loaded.', style: TextStyle(color: Colors.white70)),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(title)),
      body: InteractiveViewer(
        key: const ValueKey('image-viewer'),
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: data != null
              ? Image.memory(data, fit: BoxFit.contain, errorBuilder: failed)
              : Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: failed,
                  loadingBuilder: (_, child, progress) =>
                      progress == null ? child : const CircularProgressIndicator(color: Colors.white),
                ),
        ),
      ),
    );
  }
}

/// Fetches a PDF and draws its pages, behind a seam so tests run without
/// the network or the printing plugin.
typedef PdfPageLoader = Stream<Uint8List> Function(String url);

Stream<Uint8List> _loadPdfPages(String url) async* {
  final uri = Uri.parse(url);
  final bytes = uri.scheme == 'data'
      ? uri.data!.contentAsBytes()
      : (await http.get(uri).timeout(const Duration(seconds: 30))).bodyBytes;
  await for (final page in Printing.raster(bytes, dpi: 144)) {
    yield await page.toPng();
  }
}

/// A PDF inside the app, page by page.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({super.key, required this.url, required this.title, this.load = _loadPdfPages});

  final String url;
  final String title;
  final PdfPageLoader load;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final _pages = <Uint8List>[];
  StreamSubscription<Uint8List>? _sub;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget
        .load(widget.url)
        .listen(
          (p) => setState(() => _pages.add(p)),
          onError: (Object e) => setState(() => _error = e),
          onDone: () => setState(() => _done = true),
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget body;
    if (_error != null && _pages.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('This document could not be loaded.', textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
        ),
      );
    } else if (_pages.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: ListView.separated(
          key: const ValueKey('pdf-pages'),
          padding: const EdgeInsets.all(12),
          itemCount: _pages.length + (_done || _error != null ? 0 : 1),
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => i < _pages.length
              ? DecoratedBox(
                  decoration: BoxDecoration(border: Border.all(color: t.colorScheme.outlineVariant)),
                  child: Image.memory(_pages[i], fit: BoxFit.fitWidth),
                )
              : const Center(
                  child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
                ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: body,
    );
  }
}
