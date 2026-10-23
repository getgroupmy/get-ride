// "Shared live with support" (migration 0282): while God View streams this
// person's position ("Live now"), the app says so, with the time left, as
// the stores ask of an app sharing someone's location. The share is read
// from my_live_share when the app starts or comes back, when a
// `location_live` push reaches the open app, and every 15 s while one is on.
// An open share also starts the native stream (BackgroundLocation.goLive),
// in case the push never woke it: an iPhone with the app closed goes live
// once it is opened.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/god_view_live.dart' show liveShareNoticeText;
import '../providers.dart';
import 'background_location.dart';
import 'push_service.dart';

/// The person's open share, on this phone's clock.
class LiveShare {
  const LiveShare({required this.id, required this.endsAt});
  final String id;
  final DateTime endsAt;
}

class LiveShareRepository {
  LiveShareRepository(this._db);
  final SupabaseClient? _db;

  /// The open share, or null (none, signed out, a database without 0282).
  Future<LiveShare?> current() async {
    final db = _db;
    if (db == null || db.auth.currentUser == null) return null;
    try {
      final res = await db.rpc('my_live_share');
      if (res is! Map || res['id'] == null) return null;
      final ends = DateTime.tryParse('${res['ends_at'] ?? ''}');
      final serverNow = DateTime.tryParse('${res['now'] ?? ''}');
      if (ends == null) return null;
      // The server's time left, counted on this phone's clock.
      final left = serverNow == null ? ends.difference(DateTime.now()) : ends.difference(serverNow);
      return LiveShare(id: '${res['id']}', endsAt: DateTime.now().add(left));
    } catch (e) {
      debugPrint('[live share] not read: $e');
      return null;
    }
  }
}

final liveShareRepositoryProvider = Provider((ref) => LiveShareRepository(ref.watch(supabaseProvider)));

/// How often an open share is read again (it may be stopped early).
const liveShareRecheck = Duration(seconds: 15);

class LiveShareController extends Notifier<LiveShare?> {
  Timer? _recheck;
  StreamSubscription<Map<String, dynamic>>? _pushes;
  AppLifecycleListener? _lifecycle;
  String? _startedFor;

  @override
  LiveShare? build() {
    final uid = ref.watch(currentUserIdProvider);
    ref.onDispose(() {
      _recheck?.cancel();
      _pushes?.cancel();
      _lifecycle?.dispose();
    });
    if (uid == null) return null;
    _pushes = PushService.instance?.received.listen((d) {
      if (d['type'] == 'location_live') unawaited(refresh());
    });
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    Future.microtask(refresh);
    return null;
  }

  Future<void> refresh() async {
    final share = await ref.read(liveShareRepositoryProvider).current();
    if (!ref.mounted) return;
    state = share;
    _recheck?.cancel();
    if (share == null) return;
    _recheck = Timer(liveShareRecheck, () => unawaited(refresh()));
    if (_startedFor != share.id) {
      _startedFor = share.id;
      unawaited(BackgroundLocation().goLive(share.endsAt));
    }
  }
}

final liveShareProvider = NotifierProvider<LiveShareController, LiveShare?>(LiveShareController.new);

/// The clock behind the time left. A seam for tests.
final liveShareClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// The small "Shared live with support · 14:55 left" pill over every page
/// while a share is on. It takes no taps: what is under it still works.
class LiveShareNotice extends ConsumerStatefulWidget {
  const LiveShareNotice({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<LiveShareNotice> createState() => _LiveShareNoticeState();
}

class _LiveShareNoticeState extends ConsumerState<LiveShareNotice> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final share = ref.watch(liveShareProvider);
    final now = ref.watch(liveShareClockProvider)();
    final on = share != null && now.isBefore(share.endsAt);
    if (on && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!on && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
    if (!on) return widget.child;
    final t = Theme.of(context);
    final bg = t.colorScheme.inverseSurface;
    final fg = t.colorScheme.onInverseSurface;
    return Stack(children: [
      widget.child,
      Positioned(
        top: MediaQuery.viewPaddingOf(context).top + 6,
        left: 16,
        right: 16,
        child: IgnorePointer(
          child: Center(
            child: Semantics(
              liveRegion: true,
              child: Material(
                key: const ValueKey('live-share-notice'),
                color: bg,
                elevation: 3,
                borderRadius: BorderRadius.circular(99),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.share_location, size: 16, color: fg),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        liveShareNoticeText(share.endsAt, now),
                        style: t.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
