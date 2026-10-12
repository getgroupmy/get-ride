// What a scanned GET code opens (migration 0161). A personal code is
// resolved with the server first and shown on a sheet:
//
//   GET.Referral  whose code it is and a way to use it (apply it signed in,
//                 or sign up with it signed out);
//   GET.me        the driver's card and "Add to My Ride";
//   GET.now       the driver's card and "Book this driver", which opens the
//                 ordinary booking with that driver as the only one asked.
//
// [openScannedGetQr] routes every other GET code where it already went
// (My Ride codes, wallet codes, invite links).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/my_qr.dart';
import '../../core/my_ride.dart';
import '../../core/referral.dart';
import '../../data/my_qr_repository.dart';
import '../../data/my_ride_repository.dart';
import '../../data/referral_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/loading_skeleton.dart';
import '../my_ride/my_ride_parts.dart'
    show FavouriteDriverTile, addFavouriteMessage, myRideUnavailableMessage, myRideWait;
import '../my_ride/my_ride_screen.dart' show showAddFavouriteSheet;
import 'direct_booking.dart';

/// A driver's code opened while signed out: where to come back to once
/// signed in (the router sends the first signed-in landing there).
class PendingQrLink {
  PendingQrLink._();
  static String? path;

  /// The pending link, cleared.
  static String? take() {
    final p = path;
    path = null;
    return p;
  }
}

/// The app path a personal code opens (`/q/<kind>/<token>`).
String qrLinkPath(QrKind kind, String token) => '/q/${kind.pathSegment}/$token';

/// Routes a scanned code: personal codes to their sheet, the rest where
/// they already went. Anything that is no GET code says so.
Future<void> openScannedGetQr(BuildContext context, WidgetRef ref, String raw) async {
  final scan = parseGetQr(raw);
  switch (scan) {
    case null:
      return;
    case PersonalQrScan():
      await showQrResultSheet(context, scan);
    case MyRideCodeScan(:final code):
      await showAddFavouriteSheet(context, code: code);
    case WalletCodeScan(:final account):
      if (account.userId == ref.read(currentUserIdProvider)) {
        showInfo(context, 'That is your own code.');
        return;
      }
      final q = {'to': account.userId, if (account.amount != null) 'amt': account.amount!.toStringAsFixed(2)};
      await context.push(Uri(path: '/wallet/trade', queryParameters: q).toString());
    case ReferralLinkScan(:final code):
      await showReferralCodeSheet(context, code);
    case OtherQrScan():
      showInfo(context, "That isn't a GET.ride code.");
  }
}

Future<void> _sheet(BuildContext context, Widget Function(VoidCallback close) child) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (c) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: ResponsiveCenter(maxWidth: 520, child: child(() => Navigator.pop(c))),
  ),
);

/// The sheet for a scanned personal code.
Future<void> showQrResultSheet(BuildContext context, PersonalQrScan scan) =>
    _sheet(context, (close) => QrResultView(scan: scan, close: close));

/// The sheet for an invite link's referral code (no owner to show).
Future<void> showReferralCodeSheet(BuildContext context, String code) =>
    _sheet(context, (close) => QrReferralResult(code: code, close: close));

/// What a scanned personal code is, with what can be done with it. [close]
/// shuts whatever it is shown in before the app goes elsewhere.
class QrResultView extends ConsumerWidget {
  const QrResultView({super.key, required this.scan, required this.close});

  final PersonalQrScan scan;
  final VoidCallback close;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final res = ref.watch(qrResolutionProvider(scan.token));
    return res.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingSkeleton(rows: 2),
      error: (_, _) => QrResultMessage(
        icon: Icons.cloud_off,
        message: "Couldn't read this code. Check your connection and try again.",
        action: OutlinedButton(
          key: const ValueKey('qr-result-retry'),
          onPressed: () => ref.invalidate(qrResolutionProvider(scan.token)),
          child: const Text('Try again'),
        ),
      ),
      data: (r) => switch (r) {
        QrActive(kind: QrKind.referral) => QrReferralResult(
          code: r.referralCode,
          ownerName: r.ownerName,
          own: r.own,
          close: close,
        ),
        QrActive() => _DriverResult(scan: scan, result: r, close: close),
        QrSignInRequired(:final kind) => QrResultMessage(
          key: const ValueKey('qr-result-sign-in'),
          icon: Icons.lock_outline,
          title: kind.label,
          message: qrResolutionMessage(r),
          action: FilledButton(
            key: const ValueKey('qr-sign-in'),
            onPressed: () {
              PendingQrLink.path = qrLinkPath(kind, scan.token);
              final router = GoRouter.of(context);
              close();
              router.go('/login');
            },
            child: const Text('Sign in to continue'),
          ),
        ),
        QrExpired() => QrResultMessage(
          key: const ValueKey('qr-result-expired'),
          icon: Icons.timer_off_outlined,
          message: qrResolutionMessage(r),
        ),
        QrRateLimited(:final retryAfter) => QrResultMessage(
          key: const ValueKey('qr-result-rate-limited'),
          icon: Icons.hourglass_empty,
          message: retryAfter == null
              ? qrResolutionMessage(r)
              : 'Too many codes tried. Try again in ${myRideWait(retryAfter)}.',
        ),
        QrUnknown() || QrNotAvailable() => QrResultMessage(
          key: const ValueKey('qr-result-unknown'),
          icon: Icons.qr_code_2,
          message: qrResolutionMessage(r),
        ),
      },
    );
  }
}

/// A message about a code, with an optional action under it.
class QrResultMessage extends StatelessWidget {
  const QrResultMessage({super.key, required this.icon, required this.message, this.title, this.action});

  final IconData icon;
  final String? title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, size: 44, color: t.colorScheme.outline),
          const SizedBox(height: 12),
          if (title != null) Text(title!, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
          Text(message, textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

// ---- GET.Referral --------------------------------------------------------------------

/// A referral code to use: applied to the signed-in account, or carried
/// into sign-up when signed out. [own]: the caller's own code.
class QrReferralResult extends ConsumerStatefulWidget {
  const QrReferralResult({super.key, required this.code, this.ownerName, this.own = false, required this.close});

  final String? code;
  final String? ownerName;
  final bool own;
  final VoidCallback close;

  @override
  ConsumerState<QrReferralResult> createState() => _QrReferralResultState();
}

class _QrReferralResultState extends ConsumerState<QrReferralResult> {
  bool _busy = false;
  String? _result;
  bool _applied = false;

  Future<void> _apply(String code) async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(referralRepositoryProvider).apply(code);
      if (!mounted) return;
      setState(() {
        _result = applyReferralMessage(r);
        _applied = r.ok;
      });
      if (r.ok) HapticFeedback.mediumImpact();
    } catch (_) {
      if (mounted) setState(() => _result = "The referral code couldn't be applied.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _signUp(String code) {
    PendingReferral.code = code;
    final router = GoRouter.of(context);
    widget.close();
    router.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final code = widget.code == null ? null : normalizeReferralCode(widget.code);
    final signedIn = ref.watch(currentUserIdProvider) != null;
    final name = widget.ownerName?.trim();
    if (code == null || code.isEmpty) {
      return const QrResultMessage(
        key: ValueKey('qr-result-unknown'),
        icon: Icons.card_giftcard,
        message: "This referral code can't be read. Ask your friend to share it again.",
      );
    }
    return Column(
      key: const ValueKey('qr-result-referral'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.card_giftcard, size: 44, color: t.colorScheme.primary),
        const SizedBox(height: 8),
        Text(QrKind.referral.label, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
        Text(
          widget.own
              ? 'This is your own referral code.'
              : name == null || name.isEmpty
              ? "You're invited to GET.ride"
              : '$name invited you to GET.ride',
          key: const ValueKey('qr-referral-headline'),
          textAlign: TextAlign.center,
          style: t.textTheme.bodyLarge,
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            code,
            key: const ValueKey('qr-referral-code'),
            textAlign: TextAlign.center,
            style: t.textTheme.headlineSmall?.copyWith(letterSpacing: 3, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 16),
        if (widget.own)
          OutlinedButton(onPressed: widget.close, child: const Text('Close'))
        else if (!signedIn)
          FilledButton(
            key: const ValueKey('qr-referral-signup'),
            onPressed: () => _signUp(code),
            child: const Text('Sign up with this code'),
          )
        else ...[
          if (_result != null) ...[
            Text(
              _result!,
              key: const ValueKey('qr-referral-result'),
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: _applied ? t.colorScheme.primary : t.colorScheme.error),
            ),
            const SizedBox(height: 12),
          ],
          if (_applied)
            FilledButton(onPressed: widget.close, child: const Text('Done'))
          else
            FilledButton(
              key: const ValueKey('qr-referral-apply'),
              onPressed: _busy ? null : () => _apply(code),
              child: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Apply referral code'),
            ),
          const SizedBox(height: 4),
          Text(
            'Referral codes can only be used while an account is new.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

// ---- GET.me / GET.now ----------------------------------------------------------------

class _DriverResult extends ConsumerStatefulWidget {
  const _DriverResult({required this.scan, required this.result, required this.close});

  final PersonalQrScan scan;
  final QrActive result;
  final VoidCallback close;

  @override
  ConsumerState<_DriverResult> createState() => _DriverResultState();
}

class _DriverResultState extends ConsumerState<_DriverResult> {
  bool _busy = false;
  bool _added = false;
  String? _error;

  QrActive get _r => widget.result;

  Future<void> _addToMyRide() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final out = await ref.read(myQrRepositoryProvider).addFavouriteByQr(widget.scan.token);
      if (!mounted) return;
      switch (out) {
        case FavouriteAdded():
          ref.invalidate(myFavouriteDriversProvider);
          HapticFeedback.mediumImpact();
          setState(() => _added = true);
        case FavouriteNotAdded(:final error, :final retryAfter):
          setState(() => _error = addFavouriteMessage(error, retryAfter: retryAfter));
        case MyRideNotAvailable():
          setState(() => _error = myRideUnavailableMessage);
      }
    } catch (_) {
      if (mounted) setState(() => _error = AddFavouriteError.unknown.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _book() {
    final booking = DirectBooking(token: widget.scan.token, driver: _r.driver);
    ref.read(directBookingProvider.notifier).set(booking);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    widget.close();
    router.go('/');
    messenger?.showSnackBar(
      SnackBar(content: Text('Choose your pickup and destination to book ${booking.driverName}.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _r;
    final d = r.driver;
    final now = r.kind == QrKind.now;
    final name = d?.name.trim().isNotEmpty == true ? d!.name.trim() : 'This driver';
    String? note;
    if (r.own) {
      note = 'This is your own ${r.kind.label} code.';
    } else if (!r.available) {
      note = now ? "$name can't take rides right now." : "$name can't be added to My Ride right now.";
    } else if (now && !r.online) {
      note = "$name isn't online right now, so they may not see your request in time.";
    }
    final blocked = r.own || !r.available;
    return Column(
      key: ValueKey('qr-result-${r.kind.wire}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(r.kind.label, style: t.textTheme.titleMedium),
        Text(
          now ? 'Book this driver directly' : 'Add this driver to My Ride',
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: d == null
              ? const ListTile(leading: Icon(Icons.person), title: Text('GET.ride driver'))
              : FavouriteDriverTile(key: const ValueKey('qr-driver-card'), driver: d, dimmed: !r.available),
        ),
        if (note != null) ...[
          const SizedBox(height: 12),
          Text(
            note,
            key: ValueKey(r.own ? 'qr-own' : (!r.available ? 'qr-unavailable' : 'qr-offline')),
            style: t.textTheme.bodyMedium?.copyWith(
              color: blocked ? t.colorScheme.error : t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const ValueKey('qr-me-error'),
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        if (now)
          FilledButton.icon(
            key: const ValueKey('qr-now-book'),
            onPressed: blocked ? null : _book,
            icon: const Icon(Icons.local_taxi_outlined),
            label: const Text('Book this driver'),
          )
        else if (_added)
          Row(
            key: const ValueKey('qr-me-added'),
            children: [
              Icon(Icons.check_circle, color: t.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text('$name added to My Ride', style: t.textTheme.titleSmall)),
            ],
          )
        else
          FilledButton.icon(
            key: const ValueKey('qr-me-add'),
            onPressed: blocked || r.alreadyFavourite || _busy ? null : _addToMyRide,
            icon: Icon(r.alreadyFavourite ? Icons.favorite : Icons.favorite_border),
            label: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(r.alreadyFavourite ? 'Already in My Ride' : 'Add to My Ride'),
          ),
        if (_added) ...[
          const SizedBox(height: 12),
          FilledButton(key: const ValueKey('qr-me-done'), onPressed: widget.close, child: const Text('Done')),
        ],
      ],
    );
  }
}
