// `/<kind>/<token>` (an app link on qr.getride.my, which a phone camera
// opens the app on) and `/q/<kind>/<token>` (codes made before it): a
// personal QR code opened as a link (a phone camera, a shared message, the
// web app). It works signed in or out — the server
// tells a signed-out visitor only what it may: a GET.Referral code's
// referral code (carried into sign-up), or "sign in" for a driver's code,
// after which the app comes back here.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/my_qr.dart';
import '../../widgets/common.dart';
import 'qr_result_sheet.dart';

class QrLinkScreen extends StatelessWidget {
  const QrLinkScreen({super.key, required this.kind, required this.token});

  /// The path's kind segment (`ref`, `me`, `now`).
  final String kind;
  final String token;

  @override
  Widget build(BuildContext context) {
    final k = QrKind.parse(kind);
    final valid = k != null && isQrToken(token);
    void home() => context.go('/');
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('qr-link-close'),
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: home,
        ),
        title: Text(k?.label ?? 'GET.ride code'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          ResponsiveCenter(
            maxWidth: 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: BrandMark(size: 48)),
                const SizedBox(height: 24),
                if (!valid)
                  QrResultMessage(
                    key: const ValueKey('qr-link-invalid'),
                    icon: Icons.qr_code_2,
                    message: qrResolutionMessage(const QrUnknown()),
                  )
                else
                  // Closing the page is going home; every action replaces it.
                  QrResultView(scan: PersonalQrScan(k, token), close: home),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
