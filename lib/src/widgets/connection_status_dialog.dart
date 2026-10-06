import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../core/connection_check.dart';

/// Pings `/auth/v1/health` once, with a 5 s limit, as Expo does at launch.
Future<ConnectionCheck> checkBackend(String url, String anonKey, {http.Client? client}) async {
  final watch = Stopwatch()..start();
  if (url.trim().isEmpty) {
    return ConnectionCheck(reachable: false, url: url, hasKey: anonKey.isNotEmpty, errorMessage: 'No server address');
  }
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(Uri.parse('$url/auth/v1/health'), headers: {'apikey': anonKey, 'Authorization': 'Bearer $anonKey'})
        .timeout(const Duration(seconds: 5));
    return ConnectionCheck(
      reachable: res.statusCode >= 200 && res.statusCode < 300,
      url: url,
      hasKey: anonKey.isNotEmpty,
      httpStatus: res.statusCode,
      durationMs: watch.elapsedMilliseconds,
    );
  } catch (e) {
    return ConnectionCheck(
      reachable: false,
      url: url,
      hasKey: anonKey.isNotEmpty,
      errorName: e is TimeoutException ? 'TimeoutError' : e.runtimeType.toString(),
      errorMessage: e is TimeoutException ? 'The server did not answer within 5 seconds' : '$e',
      durationMs: watch.elapsedMilliseconds,
    );
  } finally {
    if (client == null) c.close();
  }
}

/// The launch popup: "Connected", or "Not Connected to server" with the
/// error and its details. Only its buttons (or back) close it.
Future<void> showConnectionStatus(BuildContext context, ConnectionPopup popup, ConnectionCheck check) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConnectionStatusDialog(popup: popup, check: check),
    );

class ConnectionStatusDialog extends StatefulWidget {
  const ConnectionStatusDialog({super.key, required this.popup, required this.check});

  final ConnectionPopup popup;
  final ConnectionCheck check;

  @override
  State<ConnectionStatusDialog> createState() => _ConnectionStatusDialogState();
}

class _ConnectionStatusDialogState extends State<ConnectionStatusDialog> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ok = widget.popup == ConnectionPopup.connected;
    final color = ok ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    final c = widget.check;
    return Dialog(
      key: ValueKey(ok ? 'connection-ok' : 'connection-failed'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: color.withValues(alpha: 0.12),
                    child: Icon(ok ? Icons.check_circle_outline : Icons.wifi_off, size: 44, color: color),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  ok ? 'Connected' : 'Not Connected to server',
                  textAlign: TextAlign.center,
                  style: t.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  ok
                      ? 'Successfully connected to the server.'
                      : "Couldn't reach the server. Some features may not work.",
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium,
                ),
                if (!ok) ...[
                  if (!c.hasUrl || !c.hasKey) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Rebuild required: the server address or key is missing from this build.',
                      style: t.textTheme.bodySmall?.copyWith(color: const Color(0xFFB45309)),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Error', style: t.textTheme.labelMedium?.copyWith(color: color)),
                        const SizedBox(height: 2),
                        Text(c.error, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _details = !_details),
                    child: Text(_details ? 'Hide details' : 'Show details'),
                  ),
                  if (_details)
                    for (final (k, v) in c.details)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(child: Text(k, style: t.textTheme.bodySmall)),
                            Text(v, style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (!ok) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            final router = GoRouter.maybeOf(context);
                            Navigator.of(context).pop();
                            router?.push('/diagnostics');
                          },
                          child: const Text('Diagnose'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(ok ? 'OK' : 'Continue'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
