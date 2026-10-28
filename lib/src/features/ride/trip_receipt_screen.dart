import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/format.dart';
import '../../core/region_time.dart';
import '../../core/ride_rating.dart';
import '../../core/trip_receipt.dart';
import '../../data/fare_coin_store.dart';
import '../../data/models.dart';
import '../../data/ride_rating_repository.dart';
import '../../providers.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/pdf_actions.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/ride_rating_card.dart';
import '../../widgets/trip_safety.dart';
import 'trip_safety_parts.dart';

final tripProvider = FutureProvider.autoDispose.family<RideRequest?, String>((ref, id) async {
  final repo = ref.watch(rideRepositoryProvider);
  final r = await repo.fetch(id);
  // A rider who wasn't on the live screen at drop-off still gets the ride
  // reward; the server pays it once per ride, so this is a no-op otherwise.
  // Coins chosen at booking are applied the same way.
  if (r != null) {
    unawaited(repo.claimRideReward(r));
    unawaited(redeemChosenFareCoins(repo, ref.read(fareCoinChoiceStoreProvider), r));
  }
  return r;
});

/// A finished trip's receipt (Expo `app/ride-detail.tsx`): route, times,
/// the other party, the fare lines, and print / share as a PDF or copy as
/// text. Opened from the trip list for both the rider's and the driver's copy.
class TripReceiptScreen extends ConsumerWidget {
  const TripReceiptScreen({super.key, required this.requestId});
  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUserIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Trip receipt')),
      body: AsyncView(
        value: ref.watch(tripProvider(requestId)),
        onRetry: () => ref.invalidate(tripProvider(requestId)),
        data: (r) {
          if (r == null) {
            return const EmptyState(icon: Icons.receipt_long_outlined, title: 'Trip not found');
          }
          final asDriver = r.partnerId == uid && r.riderId != uid;
          return _ReceiptBody(
            receipt: TripReceipt.fromRide(r, asDriver: asDriver),
            route: receiptRoute(r),
            // The passenger's rating (0159) and "Left something behind?" (Phase D4).
            extra: asDriver
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RideRatingCard(ride: r),
                      LostItemCard(ride: r),
                      // Cover, permit, report and block (0311).
                      TripSafetySection(requestId: r.id),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

/// After a trip is rated (or Skip): the receipt as a "Trip summary" that
/// closes by itself after [closeAfter] (owner, 27 Oct), unless the rider
/// touches or scrolls it to read (WCAG 2.2.1); Close or the cross leave at
/// once. Closing goes home.
class TripSummaryScreen extends ConsumerStatefulWidget {
  const TripSummaryScreen({super.key, required this.requestId, this.closeAfter = tripSummaryCloseAfter, this.onClose});
  final String requestId;
  final Duration closeAfter;

  /// Instead of going home (tests).
  final VoidCallback? onClose;

  @override
  ConsumerState<TripSummaryScreen> createState() => _TripSummaryScreenState();
}

class _TripSummaryScreenState extends ConsumerState<TripSummaryScreen> {
  late int _left = widget.closeAfter.inSeconds;
  Timer? _tick;
  bool _paused = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _paused) return;
      if (_left <= 1) {
        _close();
      } else {
        setState(() => _left--);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _pause() {
    if (_paused || _closed) return;
    _tick?.cancel();
    setState(() => _paused = true);
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    _tick?.cancel();
    final done = widget.onClose;
    if (done != null) {
      done();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final uid = ref.watch(currentUserIdProvider);
    final stars = uid == null
        ? null
        : ref.watch(myRideRatingProvider((requestId: widget.requestId, riderId: uid))).value?.stars;
    final footer = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${tripSummaryRatedLine(stars)} '
            '${_paused ? 'Paused while you read. Tap Close when done.' : 'Closing in $_left s. Touch to pause.'}',
            key: const ValueKey('trip-summary-countdown'),
            textAlign: TextAlign.center,
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('trip-summary-close'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _close,
            child: const Text('Close'),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Trip summary'),
        actions: [
          IconButton(
            key: const ValueKey('trip-summary-x'),
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
        ],
      ),
      // Touching or scrolling the receipt stops the countdown.
      body: Listener(
        onPointerDown: (_) => _pause(),
        child: NotificationListener<ScrollStartNotification>(
          onNotification: (_) {
            _pause();
            return false;
          },
          child: AsyncView(
            value: ref.watch(tripProvider(widget.requestId)),
            onRetry: () => ref.invalidate(tripProvider(widget.requestId)),
            data: (r) => r == null
                ? ListView(padding: const EdgeInsets.all(16), children: [footer])
                : _ReceiptBody(
                    receipt: TripReceipt.fromRide(r, asDriver: false),
                    route: receiptRoute(r),
                    extra: footer,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The booking number at the top of the receipt; a tap copies it.
class _BookingIdRow extends StatelessWidget {
  const _BookingIdRow({required this.bookingNo});
  final String bookingNo;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: bookingNo));
    if (!context.mounted) return;
    unawaited(
      showAppNotice(id: 'notice.trip-receipt', context: context, message: 'Booking ID copied', kind: NoticeKind.success),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      key: const ValueKey('receipt-booking-id'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _copy(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 0, 8),
        child: Row(
          children: [
            Text('Booking ID', style: t.textTheme.titleSmall),
            const SizedBox(width: 12),
            // All the room the label leaves, and shrunk rather than cut off
            // at large text: the ID is read out to support.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(bookingNo, style: t.textTheme.bodyMedium, maxLines: 1),
              ),
            ),
            IconButton(
              key: const ValueKey('receipt-copy-booking-id'),
              tooltip: 'Copy booking ID',
              icon: const Icon(Icons.copy_outlined, size: 20),
              onPressed: () => _copy(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// The receipt map's height, and the margin its route is framed with
/// above and below.
const receiptMapHeight = 200.0;
const receiptMapMargin = 28.0;

/// The room above the framed route: the pickup pin's height over its point
/// and a little air.
const receiptMapPinRoom = rideMapPinTop + 8;

class _ReceiptBody extends StatelessWidget {
  const _ReceiptBody({required this.receipt, this.route = const [], this.extra});
  final TripReceipt receipt;

  /// Shown under the total (the passenger's lost item card).
  final Widget? extra;

  /// Pickup, stops, drop-off ([receiptRoute]); no map when empty.
  final List<LatLng> route;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rc = receipt;
    final ok = rc.status == RideStatus.completed;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ResponsiveCenter(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BookingIdRow(bookingNo: rc.bookingNo),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(
                        ok ? Icons.check_circle : Icons.cancel_outlined,
                        size: 48,
                        color: ok ? Colors.green : t.colorScheme.error,
                      ),
                      const SizedBox(height: 8),
                      Text(rc.statusLabel, style: t.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        rc.charged ? formatMoney(rc.total, rc.currency) : 'No charge',
                        key: const ValueKey('receipt-total'),
                        style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ),
              ?extra,
              if (route.isNotEmpty)
                Card(
                  key: const ValueKey('receipt-map'),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: receiptMapHeight,
                    // A picture of the trip, not a map to explore: Expo's
                    // receipt map takes no gestures either. Framed on the
                    // planned route with a slim margin (the map's usual 64
                    // all round left a 200 high card showing the whole
                    // Klang Valley); the pickup alone at street level.
                    child: IgnorePointer(
                      child: RideMap(
                        pickup: route.first,
                        drop: route.length > 1 ? route.last : null,
                        stops: route.length > 2 ? route.sublist(1, route.length - 1) : const [],
                        route: route.length > 1 ? route : const [],
                        // Room above for the pickup pin, which stands on
                        // its point (it was cut to its base at the top
                        // edge); the slim margin below.
                        fitTop: receiptMapPinRoom,
                        fitBottom: receiptMapMargin,
                        pointZoom: 16,
                      ),
                    ),
                  ),
                ),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
                      title: Text(rc.pickup),
                      // Said what it is ("Picked up 8:02 PM"), and only for
                      // a trip that ran: under a cancelled trip's pickup a
                      // bare time read as when it was to be.
                      subtitle: !rc.charged || rc.startedAt == null
                          ? null
                          : Text(
                              'Picked up ${formatInZone(rc.startedAt, rc.timezone, pattern: 'h:mm a')}',
                              key: const ValueKey('receipt-picked-up'),
                            ),
                    ),
                    ListTile(
                      leading: Icon(Icons.location_on, color: Colors.red.shade700),
                      title: Text(rc.drop),
                      subtitle: !rc.charged || rc.endedAt == null
                          ? null
                          : Text('Dropped off ${formatInZone(rc.endedAt, rc.timezone, pattern: 'h:mm a')}'),
                    ),
                  ],
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (k, v) in rc.details) _row(t, k, v),
                      if (rc.charged) ...[
                        const Divider(height: 24),
                        for (final l in rc.lines) _row(t, l.label, formatMoney(l.amount, rc.currency)),
                        const SizedBox(height: 4),
                        _row(t, rc.totalLabel, formatMoney(rc.total, rc.currency), bold: true),
                      ],
                      if (rc.charged && rc.asDriver) ...[
                        const Divider(height: 24),
                        _row(
                          t,
                          rc.commissionLabel,
                          rc.commission == null ? 'Not charged yet' : '−${formatMoney(rc.commission, rc.currency)}',
                        ),
                        if (rc.platformFees > 0) ...[
                          const SizedBox(height: 4),
                          _row(t, 'Platform fees', '−${formatMoney(rc.platformFees, rc.currency)}'),
                        ],
                        if (rc.standFee > 0) ...[
                          const SizedBox(height: 4),
                          _row(t, 'Stand fee', '−${formatMoney(rc.standFee, rc.currency)}'),
                        ],
                        const SizedBox(height: 4),
                        KeyedSubtree(
                          key: const ValueKey('receipt-earnings'),
                          child: _row(t, 'You earn', formatMoney(rc.earnings, rc.currency), bold: true),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  BusyButton.outlined(
                    key: const ValueKey('receipt-print'),
                    icon: const Icon(Icons.print_outlined),
                    onPressed: () => Printing.layoutPdf(
                      name: 'GET.ride ${rc.bookingNo}',
                      onLayout: (format) => buildTripReceiptPdf(rc, format: format),
                    ),
                    child: const Text('Print'),
                  ),
                  // Share or download, asked on tap.
                  BusyButton.outlined(
                    key: const ValueKey('receipt-pdf'),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    onPressed: () => sharePdfOrDownload(
                      context,
                      filename: '${rc.bookingNo}.pdf',
                      title: 'Receipt ${rc.bookingNo}',
                      build: () => buildTripReceiptPdf(rc),
                    ),
                    child: const Text('PDF'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(ThemeData t, String k, String v, {bool bold = false}) {
    final style = bold ? t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800) : t.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The value gets the larger share, and a time keeps its AM/PM on
          // its line.
          Expanded(
            flex: 2,
            child: Text(k, style: bold ? style : style?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 12),
          Flexible(
            flex: 3,
            child: Text(
              v.replaceAll(' AM', ' AM').replaceAll(' PM', ' PM'),
              textAlign: TextAlign.end,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// The receipt as an A4 (or [format]) PDF page. Text is kept to the base
/// font's character set, so the route is written "A to B".
Future<Uint8List> buildTripReceiptPdf(TripReceipt rc, {PdfPageFormat format = PdfPageFormat.a4}) {
  final doc = pw.Document(title: 'GET.ride receipt ${rc.bookingNo}', author: 'GET.ride');
  pw.Widget row(String k, String v, {bool bold = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(k, style: pw.TextStyle(color: bold ? PdfColors.black : PdfColors.grey700)),
        ),
        pw.Text(v, style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ],
    ),
  );
  doc.addPage(
    pw.Page(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('GET.ride', style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold)),
          pw.Text('Trip receipt', style: const pw.TextStyle(color: PdfColors.grey700)),
          pw.SizedBox(height: 20),
          pw.Text(
            rc.charged ? formatMoney(rc.total, rc.currency) : 'No charge',
            style: pw.TextStyle(fontSize: 30, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Text('${rc.pickup} to ${rc.drop}'),
          pw.Divider(height: 24),
          for (final (k, v) in rc.details) row(k, v),
          if (rc.charged) ...[
            pw.Divider(height: 24),
            for (final l in rc.lines) row(l.label, formatMoney(l.amount, rc.currency)),
            row(rc.totalLabel, formatMoney(rc.total, rc.currency), bold: true),
          ],
          pw.Spacer(),
          pw.Text(
            'This is a computer-generated receipt.',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
