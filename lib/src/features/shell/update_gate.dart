import '../../widgets/busy.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../core/app_version.dart';
import '../../data/app_version_repository.dart';

/// Opens the store; the store app is a different app, so this leaves ours.
typedef StoreOpener = Future<bool> Function(String url);

Future<bool> _openStore(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// SharedPreferences key: the latest version whose "update available" card
/// the user dismissed, so it is not shown again until a newer one ships.
const updateDismissedKey = 'update_dismissed_version';

/// Admin → Settings → App Version. A build the admin requires to update
/// gets an "Update required" screen in place of the app; one that is only
/// behind gets a card it can dismiss. Until the rows are read — or when they
/// cannot be — the app is shown as normal.
class UpdateGate extends ConsumerStatefulWidget {
  const UpdateGate({super.key, required this.child, this.openStore});

  final Widget child;

  /// For tests; null opens the store app.
  final StoreOpener? openStore;

  @override
  ConsumerState<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends ConsumerState<UpdateGate> {
  /// Null until read; the card waits for it so a dismissed one never flashes.
  String? _dismissed;
  bool _prefsRead = false;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    unawaited(_readDismissed());
  }

  Future<void> _readDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _dismissed = prefs.getString(updateDismissedKey);
    } catch (_) {}
    if (mounted) setState(() => _prefsRead = true);
  }

  Future<void> _dismiss(String latest) async {
    setState(() => _hidden = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(updateDismissedKey, latest);
    } catch (_) {}
  }

  Future<void> _update(UpdateVerdict v) async {
    final url = v.storeUrl;
    if (url == null) return;
    final ok = await (widget.openStore ?? _openStore)(url);
    if (!ok && mounted) setState(() => _failed = true);
  }

  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(appUpdateProvider).value ?? const UpdateVerdict.none();
    if (v.kind == UpdateKind.required) {
      return UpdateRequiredView(verdict: v, onUpdate: () => _update(v), failed: _failed);
    }
    final showCard = v.kind == UpdateKind.optional && _prefsRead && !_hidden && _dismissed != v.latest;
    if (!showCard) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _UpdateCard(
                  verdict: v,
                  onLater: () => _dismiss(v.latest!),
                  onUpdate: v.storeUrl == null ? null : () => _update(v),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.verdict, required this.onLater, required this.onUpdate});

  final UpdateVerdict verdict;
  final VoidCallback onLater;
  final BusyAction? onUpdate;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.system_update, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('Update available', style: Theme.of(context).textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              onUpdate == null
                  ? 'Version ${verdict.latest} is out. Update from your app store.'
                  : 'Version ${verdict.latest} is out (you have ${AppConfig.appVersion}).',
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onLater, child: const Text('Later')),
                if (onUpdate != null) BusyButton.filled(onPressed: onUpdate, child: const Text('Update')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Stands in for the whole app while this build is below what the admin
/// allows. There is deliberately no way past it but the store.
class UpdateRequiredView extends StatelessWidget {
  const UpdateRequiredView({super.key, required this.verdict, required this.onUpdate, this.failed = false});

  final UpdateVerdict verdict;
  final BusyAction onUpdate;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hasLink = verdict.storeUrl != null;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.system_update, size: 72, color: cs.primary),
                  const SizedBox(height: 20),
                  Text('Update required', style: text.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(
                    'This version of GET.ride (${AppConfig.appVersion}) is no longer supported. '
                    'Please update to version ${verdict.latest} to keep using the app.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (hasLink)
                    BusyButton.filled(
                      onPressed: onUpdate,
                      icon: const Icon(Icons.open_in_new),
                      child: const Text('Update now'),
                    )
                  else
                    Text(
                      'Open the App Store and update GET.ride.',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  if (failed) ...[
                    const SizedBox(height: 12),
                    Text(
                      "The store couldn't be opened. Update GET.ride from your app store.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
