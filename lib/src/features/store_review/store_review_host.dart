// After sign-in (migration 0333): the permissions notice for everyone, and
// for the store review account its mode choice (passenger or driver), the
// app itself on simulated data, an optional "Show me around" tour of step
// cards over the real screens, and the "Demo · simulated" label.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/store_review.dart';
import '../../data/auth_repository.dart';
import '../../providers.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/permissions_notice.dart';

/// Where the tour is: its mode and step, or null when it is not running.
class TourState {
  const TourState(this.mode, this.index);
  final TourMode mode;
  final int index;

  List<TourStep> get steps => tourSteps(mode);
  TourStep get step => steps[index];
  bool get last => index == steps.length - 1;
}

final reviewTourProvider = NotifierProvider<ReviewTour, TourState?>(ReviewTour.new);

class ReviewTour extends Notifier<TourState?> {
  @override
  TourState? build() {
    // A different account (or none) has no tour.
    try {
      ref.watch(currentUserIdProvider);
    } catch (_) {}
    return null;
  }

  void start(TourMode mode) => state = TourState(mode, 0);
  void next() {
    final s = state;
    if (s == null) return;
    state = s.last ? null : TourState(s.mode, s.index + 1);
  }

  void back() {
    final s = state;
    if (s == null || s.index == 0) return;
    state = TourState(s.mode, s.index - 1);
  }

  void stop() => state = null;
}

/// "Use as a passenger" / "Use as a driver": null when put away.
Future<TourMode?> showReviewModeChoice(BuildContext context) => showAppDialog<TourMode>(
  id: 'review.mode',
  context: context,
  barrierDismissible: false,
  builder: (c) => const ReviewModeDialog(),
);

class ReviewModeDialog extends StatelessWidget {
  const ReviewModeDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('review-mode'),
      scrollable: true,
      title: const Text('How do you want to use GET.ride?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This is the store review demo account. Everything works as for a real user, on simulated riders, '
            'drivers, trips and money: nothing reaches real people or real payments. You can switch any time from '
            'the menu, under How it works.',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('review-mode-passenger'),
            onPressed: () => Navigator.pop(context, TourMode.passenger),
            icon: const Icon(Icons.hail),
            label: const Text('Use as a passenger'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const ValueKey('review-mode-driver'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => Navigator.pop(context, TourMode.driver),
            icon: const Icon(Icons.local_taxi_outlined),
            label: const Text('Use as a driver'),
          ),
        ],
      ),
    );
  }
}

/// "Show me around?": true for the tour, false (or put away) for none.
Future<bool> showReviewTourOffer(BuildContext context, TourMode mode) async =>
    await showAppDialog<bool>(
      id: 'review.show-around',
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('review-show-around'),
        title: const Text('Show me around?'),
        content: Text(
          'A few short step cards point out how the ${mode == TourMode.driver ? 'driver' : 'passenger'} side works '
          'while you use it. Skip them any time; restart them from the menu, under How it works.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('review-show-around-skip'),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const ValueKey('review-show-around-yes'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Show me around'),
          ),
        ],
      ),
    ) ==
    true;

/// The route a mode opens on.
String reviewModeHome(TourMode mode) => mode == TourMode.driver ? '/drive' : '/';

/// Picks a mode, opens it, and offers the tour.
Future<void> chooseReviewMode(BuildContext context, WidgetRef ref, {GoRouter? router}) async {
  final mode = await showReviewModeChoice(context);
  if (mode == null || !context.mounted) return;
  final go = router ?? GoRouter.maybeOf(context);
  go?.go(reviewModeHome(mode));
  if (await showReviewTourOffer(context, mode)) {
    ref.read(reviewTourProvider.notifier).start(mode);
  } else {
    ref.read(reviewTourProvider.notifier).stop();
  }
}

/// Menu › How it works (the store review account): restart a tour, switch
/// mode, or read the permissions again.
Future<void> showHowItWorks(BuildContext context, WidgetRef ref) async {
  final pick = await showAppSheet<String>(
    id: 'review.how-it-works',
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('How it works'), subtitle: Text('Store review demo account: simulated data only.')),
        ListTile(
          key: const ValueKey('how-tour-passenger'),
          leading: const Icon(Icons.hail),
          title: const Text('Passenger tour'),
          onTap: () => Navigator.pop(c, 'passenger'),
        ),
        ListTile(
          key: const ValueKey('how-tour-driver'),
          leading: const Icon(Icons.local_taxi_outlined),
          title: const Text('Driver tour'),
          onTap: () => Navigator.pop(c, 'driver'),
        ),
        ListTile(
          key: const ValueKey('how-switch-mode'),
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Switch passenger / driver'),
          onTap: () => Navigator.pop(c, 'mode'),
        ),
        ListTile(
          key: const ValueKey('how-permissions'),
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('What the app asks your phone for'),
          onTap: () => Navigator.pop(c, 'permissions'),
        ),
        if (ref.read(reviewTourProvider) != null)
          ListTile(
            key: const ValueKey('how-stop'),
            leading: const Icon(Icons.close),
            title: const Text('Stop the tour'),
            onTap: () => Navigator.pop(c, 'stop'),
          ),
      ]),
    ),
  );
  if (pick == null || !context.mounted) return;
  final tour = ref.read(reviewTourProvider.notifier);
  switch (pick) {
    case 'passenger' || 'driver':
      final mode = pick == 'driver' ? TourMode.driver : TourMode.passenger;
      GoRouter.maybeOf(context)?.go(reviewModeHome(mode));
      tour.start(mode);
    case 'mode':
      await chooseReviewMode(context, ref);
    case 'permissions':
      await showPermissionsNotice(context, platform: noticePlatformOf(defaultTargetPlatform));
    case 'stop':
      tour.stop();
  }
}

/// One step card of the tour, over the real screen. Folds to a small
/// pill so it never covers what the step asks for.
class TourCard extends StatefulWidget {
  const TourCard({
    super.key,
    required this.state,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  final TourState state;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final VoidCallback onSkip;

  @override
  State<TourCard> createState() => _TourCardState();
}

class _TourCardState extends State<TourCard> {
  bool _folded = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = widget.state;
    final label = tourStepLabel(s.index, s.steps.length);
    if (_folded) {
      return Material(
        type: MaterialType.transparency,
        child: ActionChip(
          key: const ValueKey('tour-pill'),
          avatar: const Icon(Icons.tour_outlined, size: 18),
          label: Text('Tour · $label'),
          onPressed: () => setState(() => _folded = false),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Card(
        key: const ValueKey('tour-card'),
        elevation: 6,
        color: t.colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    '$label: ${s.step.title}',
                    key: const ValueKey('tour-step-title'),
                    style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  key: const ValueKey('tour-fold'),
                  onPressed: () => setState(() => _folded = true),
                  child: const Text('Hide'),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(s.step.body, style: t.textTheme.bodyMedium),
              ),
              Row(children: [
                TextButton(key: const ValueKey('tour-skip'), onPressed: widget.onSkip, child: const Text('Skip')),
                const Spacer(),
                if (s.index > 0)
                  TextButton(key: const ValueKey('tour-back'), onPressed: widget.onBack, child: const Text('Back')),
                TextButton(
                  key: const ValueKey('tour-next'),
                  onPressed: widget.onNext,
                  child: Text(s.last ? 'Finish' : 'Next'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Demo · simulated" label the store review account always sees.
class DemoSimulatedLabel extends StatelessWidget {
  const DemoSimulatedLabel({super.key});

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('demo-simulated-label'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: const Color(0xFF7C3AED), borderRadius: BorderRadius.circular(8)),
    child: const Text(
      'Demo · simulated',
      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

/// Wraps the app (above its navigator, the permission gate included).
class StoreReviewHost extends ConsumerStatefulWidget {
  const StoreReviewHost({
    super.key,
    required this.child,
    required this.location,
    this.listenable,
    this.router,
    this.platform,
    this.prefs,
    this.saveNewsOffers,
  });

  final Widget child;
  final String Function() location;
  final Listenable? listenable;
  final GoRouter? router;

  /// The phone the notice is for; the running one when null.
  final NoticePlatform? Function()? platform;

  /// SharedPreferences, for tests.
  final Future<SharedPreferences> Function()? prefs;

  /// Saves "Send me news and offers" when ticked (set_news_offers); a
  /// stand-in in tests.
  final Future<void> Function(bool on)? saveNewsOffers;

  @override
  ConsumerState<StoreReviewHost> createState() => _StoreReviewHostState();
}

class _StoreReviewHostState extends ConsumerState<StoreReviewHost> {
  /// The accounts the notice was shown to in this run of the app.
  final _shownFor = <String>{};
  final _nav = GlobalKey<NavigatorState>();
  bool _showing = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.listenable?.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    widget.listenable?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) unawaited(_maybeShow());
  }

  NoticePlatform? get _platform =>
      widget.platform != null ? widget.platform!() : noticePlatformOf(defaultTargetPlatform);

  Future<void> _maybeShow() async {
    if (_busy) return;
    String? uid;
    try {
      uid = ref.read(currentUserIdProvider);
    } catch (_) {
      return;
    }
    if (uid == null) {
      _shownFor.clear();
      return;
    }
    final loc = widget.location();
    if (loc.startsWith('/login') || loc.startsWith('/signup') || loc == '/diagnostics') return;
    // Looked at once per account per run (and again after signing in anew).
    if (_shownFor.contains(uid)) return;
    final review = ref.read(storeReviewProvider);
    final platform = _platform;
    if (platform == null && !review) return;
    _busy = true;
    try {
      SharedPreferences? prefs;
      try {
        prefs = await (widget.prefs ?? SharedPreferences.getInstance)();
      } catch (_) {}
      final due = permissionNoticeDue(
        storeReview: review,
        seenVersion: prefs?.getInt(permissionNoticeKey(uid)),
        shownThisRun: _shownFor.contains(uid),
      );
      _shownFor.add(uid);
      if (!due || !mounted) return;
      setState(() => _showing = true);
      await WidgetsBinding.instance.endOfFrame;
      final nav = _nav.currentContext;
      if (nav == null || !nav.mounted) return;
      final news = await showPermissionsNotice(nav, platform: platform);
      if (news) {
        try {
          await (widget.saveNewsOffers ??
              (v) => ref.read(supabaseProvider).rpc('set_news_offers', params: {'p_on': v}))(true);
          ref.invalidate(profileProvider);
        } catch (_) {}
      }
      try {
        await prefs?.setInt(permissionNoticeKey(uid), permissionNoticeVersion);
      } catch (_) {}
      if (review && nav.mounted) {
        AuthRepository.storeReviewSignedIn = false;
        await chooseReviewMode(nav, ref, router: widget.router);
      }
    } finally {
      _busy = false;
      if (mounted && _showing) setState(() => _showing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentUserIdProvider, (_, _) => _changed());
    ref.listen<TourState?>(reviewTourProvider, (prev, next) {
      if (next == null) return;
      if (prev?.mode == next.mode && prev?.index == next.index) return;
      final route = next.step.route;
      if (widget.location() != route) widget.router?.go(route);
    });
    final review = ref.watch(storeReviewProvider);
    final tour = ref.watch(reviewTourProvider);
    final tourNotifier = ref.read(reviewTourProvider.notifier);
    return Stack(
      children: [
        widget.child,
        if (_showing)
          Positioned.fill(
            child: HeroControllerScope.none(
              child: Navigator(
                key: _nav,
                pages: const [MaterialPage<void>(key: ValueKey('store-review-host'), child: SizedBox.shrink())],
                onDidRemovePage: (_) {},
              ),
            ),
          ),
        if (review)
          const Positioned(
            left: 8,
            bottom: 8,
            child: SafeArea(child: IgnorePointer(child: DemoSimulatedLabel())),
          ),
        if (review && tour != null && !_showing)
          Positioned(
            left: 12,
            right: 12,
            top: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 56),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: TourCard(
                    key: ValueKey('tour-${tour.mode.name}-${tour.index}'),
                    state: tour,
                    onNext: tourNotifier.next,
                    onBack: tourNotifier.back,
                    onSkip: tourNotifier.stop,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
