// "My QR": the account's personal QR codes (migration 0161), one tab per
// kind it may hold — GET.Referral for everyone, GET.me and GET.now for
// drivers too. Each kind has at most one active code: it can be shared,
// saved, expired now or replaced by a new one, and an earlier one can be
// used again, each with an optional auto-expiry.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/my_qr.dart';
import '../../data/my_qr_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/image_share.dart';
import '../../widgets/side_menu_host.dart';
import '../my_ride/my_ride_parts.dart' show myRideWait;
import '../my_ride/my_ride_screen.dart' show MyRideScanScreen;
import 'qr_result_sheet.dart';

/// The clock the page reads codes against; overridden in tests.
final myQrClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// The auto-expiry a new or reused code starts with: never, as the server's
/// own default; the owner picks another each time.
const myQrDefaultTtl = QrTtl.never;

const myQrUnavailableMessage = "My QR isn't available yet. Please check back later.";

/// What a refusal tells the owner, with the wait when the server gave one.
String myQrRefusedMessage(MyQrError e, {Duration? retryAfter}) => e == MyQrError.rateLimited && retryAfter != null
    ? 'Too many changes. Try again in ${myRideWait(retryAfter)}.'
    : e.message;

/// "12 Oct 2026".
String myQrDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = d.toLocal();
  return '${l.day} ${months[l.month - 1]} ${l.year}';
}

/// An earlier code's dates: "Made 12 Oct 2026 · Expired 13 Oct 2026".
String myQrHistoryDates(PersonalQr qr) {
  final made = qr.createdAt;
  final ended = qr.status == QrStatus.revoked ? qr.revokedAt ?? qr.expiresAt : qr.expiresAt ?? qr.revokedAt;
  return [
    if (made != null) 'Made ${myQrDate(made)}',
    if (ended != null) '${qr.status == QrStatus.revoked ? 'Turned off' : 'Expired'} ${myQrDate(ended)}',
  ].join(' · ');
}

/// The colour each kind's code is drawn in (on white, in both themes).
Color myQrColor(QrKind k) => switch (k) {
  QrKind.referral => const Color(0xFF7C3AED),
  QrKind.me => const Color(0xFFBE185D),
  QrKind.now => const Color(0xFF0F766E),
};

IconData myQrIcon(QrKind k) => switch (k) {
  QrKind.referral => Icons.card_giftcard,
  QrKind.me => Icons.favorite_border,
  QrKind.now => Icons.local_taxi_outlined,
};

class MyQrScreen extends ConsumerStatefulWidget {
  const MyQrScreen({super.key});

  @override
  ConsumerState<MyQrScreen> createState() => _MyQrScreenState();
}

class _MyQrScreenState extends ConsumerState<MyQrScreen> {
  Timer? _tick;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Expiry text ("Expires in 3 h") and a code running out on its own.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const MyRideScanScreen(universal: true), fullscreenDialog: true));
    if (raw == null || !mounted) return;
    await openScannedGetQr(context, ref, raw);
  }

  /// Runs a change and says how it went.
  Future<void> _run(Future<MyQrResult> Function(MyQrRepository repo) change, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final out = await change(ref.read(myQrRepositoryProvider));
      if (!mounted) return;
      switch (out) {
        case MyQrDone():
          ref.invalidate(myQrCodesProvider);
          showInfo(context, done);
        case MyQrRefused(:final error, :final retryAfter):
          if (error == MyQrError.notFound || error == MyQrError.notReactivatable) ref.invalidate(myQrCodesProvider);
          showInfo(context, myQrRefusedMessage(error, retryAfter: retryAfter));
        case MyQrNotAvailable():
          ref.invalidate(myQrCodesProvider);
          showInfo(context, myQrUnavailableMessage);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate(QrKind kind, {required bool replaces}) async {
    final ttl = await showQrLifetimeDialog(
      context,
      title: replaces ? 'Generate a new ${kind.label} code?' : 'Generate a ${kind.label} code',
      message: replaces ? 'Your current ${kind.label} code will stop working.' : null,
      confirmLabel: replaces ? 'Generate new' : 'Generate',
    );
    if (ttl == null || !mounted) return;
    await _run((r) => r.generate(kind, ttl: ttl), 'Your new ${kind.label} code is ready.');
  }

  Future<void> _expire(PersonalQr qr) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Expire your ${qr.kind.label} code?'),
        content: const Text(
          'It stops working now. You can generate a new one, or reuse this one later from Earlier codes.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('my-qr-expire-cancel'),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('my-qr-expire-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Expire now'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run((r) => r.expire(qr.id), 'Your ${qr.kind.label} code has expired.');
  }

  Future<void> _reuse(PersonalQr qr, {required bool replaces}) async {
    final ttl = await showQrLifetimeDialog(
      context,
      title: 'Reuse this ${qr.kind.label} code?',
      message: replaces ? 'This will expire your current ${qr.kind.label} code.' : null,
      confirmLabel: 'Reuse',
    );
    if (ttl == null || !mounted) return;
    await _run((r) => r.reactivate(qr.id, ttl: ttl), 'Your earlier ${qr.kind.label} code works again.');
  }

  @override
  Widget build(BuildContext context) {
    final codes = ref.watch(myQrCodesProvider);
    final isPartner = ref.watch(partnerProvider).value != null;
    final kinds = qrKindsFor(isPartner: isPartner);
    final now = ref.watch(myQrClockProvider)();
    final available = codes.value != null || codes.isLoading || codes.hasError;
    Widget panel(QrKind k) => AsyncView(
      value: codes,
      onRetry: () => ref.invalidate(myQrCodesProvider),
      data: (list) => _KindPanel(
        key: PageStorageKey('my-qr-panel-${k.wire}'),
        kind: k,
        codes: list ?? const [],
        now: now,
        busy: _busy,
        onRefresh: () async {
          ref.invalidate(myQrCodesProvider);
          try {
            await ref.read(myQrCodesProvider.future);
          } catch (_) {}
        },
        onGenerate: (replaces) => _generate(k, replaces: replaces),
        onExpire: _expire,
        onReuse: _reuse,
      ),
    );
    final appBar = AppBar(
      leading: context.canPop() ? null : sideMenuLeading(context),
      title: const Text('My QR'),
      actions: [
        IconButton(
          key: const ValueKey('my-qr-scan'),
          tooltip: 'Scan a code',
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: _scan,
        ),
      ],
      bottom: kinds.length > 1 && available
          ? TabBar(
              key: const ValueKey('my-qr-tabs'),
              tabs: [for (final k in kinds) Tab(key: ValueKey('my-qr-tab-${k.wire}'), text: k.label)],
            )
          : null,
    );
    if (codes.hasValue && codes.value == null) {
      return Scaffold(
        appBar: appBar,
        body: const EmptyState(
          key: ValueKey('my-qr-unavailable'),
          icon: Icons.qr_code_2,
          title: "My QR isn't available yet",
          message: 'Personal QR codes are coming soon. Please check back later.',
        ),
      );
    }
    if (kinds.length == 1) return Scaffold(appBar: appBar, body: panel(kinds.single));
    return DefaultTabController(
      key: ValueKey('my-qr-kinds-${kinds.length}'),
      length: kinds.length,
      child: Scaffold(
        appBar: appBar,
        body: TabBarView(children: [for (final k in kinds) panel(k)]),
      ),
    );
  }
}

/// One kind's page: its active code (or a way to make one) and the codes
/// it had before.
class _KindPanel extends StatelessWidget {
  const _KindPanel({
    super.key,
    required this.kind,
    required this.codes,
    required this.now,
    required this.busy,
    required this.onRefresh,
    required this.onGenerate,
    required this.onExpire,
    required this.onReuse,
  });

  final QrKind kind;
  final List<PersonalQr> codes;
  final DateTime now;
  final bool busy;
  final Future<void> Function() onRefresh;
  final void Function(bool replaces) onGenerate;
  final void Function(PersonalQr qr) onExpire;
  final void Function(PersonalQr qr, {required bool replaces}) onReuse;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final active = activeQr(codes, kind, now);
    final history = qrHistory(codes, kind, now);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        key: ValueKey('my-qr-list-${kind.wire}'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          ResponsiveCenter(
            maxWidth: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(myQrIcon(kind), color: t.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(kind.label, style: t.textTheme.titleLarge)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(kind.description, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                if (active != null)
                  _ActiveCode(
                    qr: active,
                    now: now,
                    busy: busy,
                    onExpire: () => onExpire(active),
                    onRegenerate: () => onGenerate(true),
                  )
                else
                  _NoCode(kind: kind, busy: busy, onGenerate: () => onGenerate(false)),
                if (history.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('Earlier codes', style: t.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Your last 10 codes can be reused: the same QR works again.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final (i, qr) in history.indexed) ...[
                          if (i > 0) const Divider(height: 1),
                          _HistoryRow(
                            qr: qr,
                            busy: busy,
                            onReuse: qr.reactivatable ? () => onReuse(qr, replaces: active != null) : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveCode extends ConsumerWidget {
  const _ActiveCode({
    required this.qr,
    required this.now,
    required this.busy,
    required this.onExpire,
    required this.onRegenerate,
  });

  final PersonalQr qr;
  final DateTime now;
  final bool busy;
  final VoidCallback onExpire;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final kind = qr.kind;
    final color = myQrColor(kind);
    final name = ref.watch(profileProvider).value?.name?.trim();
    final caption = [kind.label, if (name != null && name.isNotEmpty) name].join(' · ');
    return Card(
      key: ValueKey('my-qr-active-${kind.wire}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  // Dark on white in both themes so every scanner reads it.
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color, width: 4),
                ),
                child: LayoutBuilder(
                  builder: (_, c) => QrImageView(
                    key: ValueKey('my-qr-code-${kind.wire}'),
                    data: qr.payload,
                    size: c.maxWidth.isFinite ? c.maxWidth.clamp(160.0, 240.0) : 240,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: color),
                    dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: color),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              qrStatusText(qr, now),
              key: ValueKey('my-qr-status-${kind.wire}'),
              textAlign: TextAlign.center,
              style: t.textTheme.titleSmall,
            ),
            if (qr.lastActivatedAt ?? qr.createdAt case final since?)
              Text(
                'Since ${myQrDate(since)}',
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            const SizedBox(height: 16),
            ShareSaveImageButtons(
              keyPrefix: 'my-qr-${kind.wire}',
              image: (origin) async => ShareableImage(
                png: await ref.read(qrPngRendererProvider)(qr.payload, color: color, caption: caption),
                fileName: 'getride-${kind.pathSegment}-qr.png',
                text: '${kind.description}\n${qr.payload}',
                subject: 'My ${kind.label} code',
                origin: origin,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: ValueKey('my-qr-regenerate-${kind.wire}'),
              onPressed: busy ? null : onRegenerate,
              icon: const Icon(Icons.autorenew),
              label: const Text('Generate new'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: ValueKey('my-qr-expire-${kind.wire}'),
              onPressed: busy ? null : onExpire,
              icon: const Icon(Icons.timer_off_outlined),
              label: const Text('Expire now'),
              style: OutlinedButton.styleFrom(foregroundColor: t.colorScheme.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoCode extends StatelessWidget {
  const _NoCode({required this.kind, required this.busy, required this.onGenerate});

  final QrKind kind;
  final bool busy;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: ValueKey('my-qr-empty-${kind.wire}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.qr_code_2, size: 56, color: t.colorScheme.outline),
            const SizedBox(height: 8),
            Text('No active ${kind.label} code', textAlign: TextAlign.center, style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Generate one to share. You choose when it expires, and you can expire it any time.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: ValueKey('my-qr-generate-${kind.wire}'),
              onPressed: busy ? null : onGenerate,
              icon: const Icon(Icons.add),
              label: const Text('Generate'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.qr, required this.busy, this.onReuse});

  final PersonalQr qr;
  final bool busy;
  final VoidCallback? onReuse;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tail = qr.token.length > 4 ? qr.token.substring(qr.token.length - 4) : qr.token;
    final dates = myQrHistoryDates(qr);
    return ListTile(
      key: ValueKey('my-qr-history-${qr.id}'),
      leading: Icon(Icons.qr_code_2, color: t.colorScheme.outline),
      title: Text('Code …$tail', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      subtitle: Text([qr.status.label, if (dates.isNotEmpty) dates].join(' · ')),
      trailing: onReuse == null
          ? null
          : TextButton(
              key: ValueKey('my-qr-reuse-${qr.id}'),
              onPressed: busy ? null : onReuse,
              child: const Text('Reuse'),
            ),
    );
  }
}

/// Asks how long a new or reused code lasts; null when dismissed.
Future<QrTtl?> showQrLifetimeDialog(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
}) => showDialog<QrTtl>(
  context: context,
  builder: (_) => _LifetimeDialog(title: title, message: message, confirmLabel: confirmLabel),
);

class _LifetimeDialog extends StatefulWidget {
  const _LifetimeDialog({required this.title, this.message, required this.confirmLabel});

  final String title;
  final String? message;
  final String confirmLabel;

  @override
  State<_LifetimeDialog> createState() => _LifetimeDialogState();
}

class _LifetimeDialogState extends State<_LifetimeDialog> {
  QrTtl _ttl = myQrDefaultTtl;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('my-qr-lifetime'),
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  widget.message!,
                  key: const ValueKey('my-qr-lifetime-warning'),
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Expires automatically after', style: t.textTheme.labelLarge),
            ),
            RadioGroup<QrTtl>(
              groupValue: _ttl,
              onChanged: (v) {
                if (v != null) setState(() => _ttl = v);
              },
              child: Column(
                children: [
                  for (final ttl in QrTtl.values)
                    RadioListTile<QrTtl>(
                      key: ValueKey('my-qr-ttl-${ttl.name}'),
                      value: ttl,
                      dense: true,
                      title: Text(ttl == QrTtl.never ? 'Never (until you expire it)' : ttl.label),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('my-qr-lifetime-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('my-qr-lifetime-confirm'),
          onPressed: () => Navigator.pop(context, _ttl),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
