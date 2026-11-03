// Safety location case (migration 0337): an admin has turned on this user's
// background location for a safety case. It is ALWAYS disclosed to the user
// while active — a one-time modal or a standing green banner, plus a standing
// row in Settings > Safety. The invariant in code: the app calls
// safety_location_ack() (which is what unlocks server-side background reports)
// ONLY after it has actually shown the modal or rendered the banner. There is
// no path that acks without first showing something.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config.dart';
import '../../providers.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/in_app_page.dart';

/// The signed-in user's open safety case, as safety_location_state() gives it.
class SafetyLocationCase {
  const SafetyLocationCase({required this.style, required this.reason, this.since, required this.notified});

  /// 'modal' (a one-time modal) or 'banner' (a standing green strip).
  final String style;

  /// A short, non-alarming phrase for the user (never the admin's exact note).
  final String reason;

  /// When the case was opened (shown in the Settings row).
  final DateTime? since;

  /// Whether the user's app has already shown the indicator once (set by the
  /// ack, server-side, and shared across the user's devices).
  final bool notified;

  bool get isBanner => style == 'banner';

  /// The open case, or null (none, signed out, a database without 0337).
  static SafetyLocationCase? fromJson(dynamic json) {
    if (json is! Map || json['active'] != true) return null;
    return SafetyLocationCase(
      style: json['style'] == 'banner' ? 'banner' : 'modal',
      reason: (json['reason'] as String?)?.trim().isNotEmpty == true ? json['reason'] as String : 'a safety review',
      since: DateTime.tryParse('${json['since'] ?? ''}')?.toLocal(),
      notified: json['notified'] == true,
    );
  }
}

class SafetyLocationRepository {
  SafetyLocationRepository(this._db);
  final SupabaseClient? _db;

  Future<SafetyLocationCase?> current() async {
    final db = _db;
    if (db == null || db.auth.currentUser == null) return null;
    try {
      return SafetyLocationCase.fromJson(await db.rpc('safety_location_state'));
    } catch (e) {
      debugPrint('[safety location] not read: $e');
      return null;
    }
  }

  /// Called only after the indicator has been shown. Sets notified_at.
  Future<SafetyLocationCase?> ack() async {
    final db = _db;
    if (db == null || db.auth.currentUser == null) return null;
    try {
      return SafetyLocationCase.fromJson(await db.rpc('safety_location_ack'));
    } catch (e) {
      debugPrint('[safety location] ack failed: $e');
      return null;
    }
  }
}

final safetyLocationRepositoryProvider =
    Provider((ref) => SafetyLocationRepository(ref.watch(supabaseProvider)));

/// How often the active case is re-read (the admin may change the style or
/// close it; the app reflects it live).
const safetyLocationRecheck = Duration(seconds: 20);

class SafetyLocationController extends Notifier<SafetyLocationCase?> {
  Timer? _recheck;
  AppLifecycleListener? _lifecycle;

  @override
  SafetyLocationCase? build() {
    final uid = ref.watch(currentUserIdProvider);
    ref.onDispose(() {
      _recheck?.cancel();
      _lifecycle?.dispose();
    });
    if (uid == null) return null;
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    Future.microtask(refresh);
    return null;
  }

  Future<void> refresh() async {
    final c = await ref.read(safetyLocationRepositoryProvider).current();
    if (!ref.mounted) return;
    state = c;
    _recheck?.cancel();
    _recheck = Timer(safetyLocationRecheck, () => unawaited(refresh()));
  }

  /// The disclosure has been shown: tell the server. Only call this once the
  /// modal has been shown, or the banner has rendered.
  Future<void> acknowledge() async {
    await ref.read(safetyLocationRepositoryProvider).ack();
    await refresh();
  }
}

final safetyLocationProvider =
    NotifierProvider<SafetyLocationController, SafetyLocationCase?>(SafetyLocationController.new);

/// The privacy policy, at its location / safety section.
Future<void> openSafetyLocationInfo(BuildContext context) =>
    openInApp(context, '${AppConfig.privacyUrl}#location-safety', title: 'Privacy Policy');

/// Wraps the app's pages. While a case is active it shows the indicator:
///   * modal style: a one-time modal the first time the app is foregrounded
///     after the case is active (once per user — gated on `notified` from the
///     server). It acks only when the modal has been shown.
///   * banner style: a standing green "Live Location Active" strip over every
///     page, which acks on its first render.
class SafetyLocationNotice extends ConsumerStatefulWidget {
  const SafetyLocationNotice({super.key, required this.child, this.onInfo});

  final Widget child;

  /// Opens the "Learn more" info (the privacy policy). A seam for tests.
  final Future<void> Function(BuildContext context)? onInfo;

  @override
  ConsumerState<SafetyLocationNotice> createState() => _SafetyLocationNoticeState();
}

class _SafetyLocationNoticeState extends ConsumerState<SafetyLocationNotice> {
  bool _modalShowing = false;
  bool _ackScheduled = false;

  Future<void> _info() => (widget.onInfo ?? openSafetyLocationInfo)(context);

  /// Shows the one-time modal, then acks (disclosure done). Never acks without
  /// showing it.
  Future<void> _showModalThenAck() async {
    if (_modalShowing || !mounted) return;
    _modalShowing = true;
    await showAppNotice(
      id: 'notice.safety_location',
      context: context,
      key: const ValueKey('safety-location-modal'),
      title: 'Background location is on',
      message: 'An administrator has turned on background location for your account for a safety review. '
          'Your location may be shared with GET.ride while this is on.',
      actionLabel: 'Learn more',
      onAction: () => unawaited(_info()),
      closeLabel: 'OK',
    );
    // The modal has been shown: now it is safe to ack.
    if (mounted) await ref.read(safetyLocationProvider.notifier).acknowledge();
    _modalShowing = false;
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(safetyLocationProvider);

    // Modal style, not yet shown to this user anywhere: show it once, then ack.
    if (c != null && !c.isBanner && !c.notified && !_modalShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_showModalThenAck()));
    }

    // Banner style: the green strip over every page. Ack on its first render.
    if (c != null && c.isBanner && !c.notified && !_ackScheduled) {
      _ackScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(ref.read(safetyLocationProvider.notifier).acknowledge());
      });
    }
    if (c == null || !c.isBanner) return widget.child;

    // A green strip in both themes, legible on either background.
    const bg = Color(0xFF1B7A3D);
    const fg = Colors.white;
    return Stack(children: [
      widget.child,
      Positioned(
        top: MediaQuery.viewPaddingOf(context).top,
        left: 0,
        right: 0,
        child: Material(
          key: const ValueKey('safety-location-banner'),
          color: bg,
          child: InkWell(
            onTap: () => unawaited(_info()),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: const [
                  Icon(Icons.location_on, size: 16, color: fg),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Live Location Active',
                      style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.info_outline, size: 15, color: fg),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Settings > Safety: the standing row while a case is active. Gone when the
/// case is closed.
class SafetyLocationSettingsCard extends ConsumerWidget {
  const SafetyLocationSettingsCard({super.key, this.onInfo});

  final Future<void> Function(BuildContext context)? onInfo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(safetyLocationProvider);
    if (c == null) return const SizedBox.shrink();
    final on = c.since;
    final when = on == null
        ? ''
        : ' on ${on.day.toString().padLeft(2, '0')}/${on.month.toString().padLeft(2, '0')}/${on.year}';
    return Card(
      key: const ValueKey('safety-location-card'),
      child: ListTile(
        leading: const Icon(Icons.location_on_outlined),
        title: const Text('Background location: On'),
        subtitle: Text('Turned on by GET.ride for a safety review$when. Contact support with any questions.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => (onInfo ?? openSafetyLocationInfo)(context),
      ),
    );
  }
}
