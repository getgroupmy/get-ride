// Freight (migration 0267) as drivers and admins read a request: the cargo,
// its photo, the vehicle size and the options booked (helpers, closed body,
// riding along). The photo opens once the driver has taken the request; an
// open one shows a placeholder, as the pets' photos do.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/courier.dart' show CourierConfig;
import '../../core/freight.dart';
import '../../core/partner_type_rules.dart' show RegionScope;
import '../../core/ride_chat.dart' show ridePhotoProblem;
import '../../core/ride_option_places.dart';
import '../../core/ride_option_settings.dart';
import '../../data/freight_repository.dart';
import '../../data/models.dart';
import '../../data/photo_picker.dart';
import '../../data/ride_option_places_repository.dart' show rideOptionPlacesProvider;
import '../../providers.dart';
import '../../widgets/chat_photo.dart' show choosePhotoSource;
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/net_image.dart';
import '../../widgets/page_style_host.dart';
import 'courier_parts.dart' show CourierCodeCard, CourierParcelLines;
import 'home_parts.dart' show uriImage;

/// Each freight option's icon (Material Symbols' own).
IconData freightOptionIcon(RideOptionKind k) => switch (k) {
  RideOptionKind.helperOne => Icons.person_outline,
  RideOptionKind.helperTwo => Icons.group_outlined,
  RideOptionKind.closedBody => Icons.shield_outlined,
  RideOptionKind.rideAlong => Icons.airline_seat_recline_normal,
  _ => Icons.tune,
};

/// A freight size's picture, else the lorry icon.
class FreightVehicleImage extends StatelessWidget {
  const FreightVehicleImage({super.key, required this.vehicle, this.size = 46});
  final FreightVehicle? vehicle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.local_shipping_outlined, size: size * 0.75, color: Theme.of(context).colorScheme.primary);
    return SizedBox.square(
      dimension: size,
      child: Center(child: uriImage(vehicle?.image, width: size, height: size, fallback: icon)),
    );
  }
}

/// The cargo photo at [path], through its signed link.
class CargoPhoto extends ConsumerWidget {
  const CargoPhoto({super.key, required this.path, required this.side, this.fit = BoxFit.cover});
  final String path;
  final double side;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = Icon(Icons.inventory_2_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant, size: side * 0.4);
    final url = ref.watch(freightCargoPhotoUrlProvider(path)).value;
    if (url == null) return SizedBox.square(dimension: side, child: Center(child: box));
    return NetImage(url, width: side, height: side, fit: fit, radius: 0, fallback: SizedBox.square(dimension: side, child: Center(child: box)));
  }
}

/// A larger look at the cargo photo.
Future<void> showCargoPhoto(BuildContext context, String path) => showAppDialog<void>(id: 'ride.freight-cargo-photo',
  context: context,
  builder: (c) {
    final t = Theme.of(c);
    final side = (MediaQuery.sizeOf(c).shortestSide - 96).clamp(160.0, 420.0);
    return Dialog(
      key: const ValueKey('cargo-photo-dialog'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: t.colorScheme.surfaceContainerHighest,
              child: InteractiveViewer(maxScale: 4, child: CargoPhoto(path: path, side: side, fit: BoxFit.contain)),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('cargo-photo-close'),
              onPressed: () => Navigator.pop(c),
              child: const Text('Close'),
            ),
          ),
        ]),
      ),
    );
  },
);

/// A freight request's cargo for the driver (request sheet, queue card,
/// trip screen) and admins: the description, the vehicle size with its
/// load, the options booked under their booked names, and the photo.
/// [locked]: the request is still open, when only the rider sees the photo.
class FreightCargoView extends ConsumerWidget {
  const FreightCargoView({super.key, required this.request, this.locked = false, this.title});
  final RideRequest request;
  final bool locked;

  /// A heading over it ("Cargo"); none on the compact request card.
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final description = r.cargoDescription;
    if (description == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    // A courier delivery's vehicle is among the courier ones (0268).
    final kind = r.isCourier ? DeliveryKind.courier : DeliveryKind.freight;
    final vehicle = freightVehicleNamed(ref.watch(deliveryVehiclesProvider(kind)).value ?? const [], r.service);
    final options = freightOptionsOf(r.optionNames);
    final path = r.cargoPhotoPath;
    final size = [
      ?vehicle?.loadText,
      ?vehicle?.sizeText,
      if (vehicle?.closedBody ?? false) 'closed body',
    ];
    return Column(
      key: ValueKey('freight-cargo-${r.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          Text(title!, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.inventory_2_outlined, size: 18, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              description,
              key: const ValueKey('freight-cargo-description'),
              style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        if (r.service != null) ...[
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.local_shipping_outlined, size: 18, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                [vehicle?.shortName ?? r.service!, ...size].join(' · '),
                key: const ValueKey('freight-cargo-vehicle'),
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ]),
        ],
        // Courier (0268): the parcel size, and the cash the recipient pays.
        if (r.isCourier)
          Padding(padding: const EdgeInsets.only(top: 4), child: CourierParcelLines(request: r)),
        if (r.declaredValue case final v?)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 24),
            child: Text(
              'Declared value ${formatMoney(v, r.currency)}',
              key: const ValueKey('freight-cargo-declared'),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        if (options.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in options)
              Chip(
                key: ValueKey('freight-cargo-option-${k.id}'),
                visualDensity: VisualDensity.compact,
                avatar: Icon(freightOptionIcon(k), size: 16),
                label: Text(r.optionNames[k.id] ?? k.defaultLabel),
              ),
          ]),
        ],
        if (path != null) ...[
          const SizedBox(height: 8),
          Material(
            color: t.colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('freight-cargo-photo'),
              onTap: locked ? null : () => showCargoPhoto(context, path),
              child: SizedBox.square(
                dimension: 64,
                child: locked
                    ? Icon(Icons.add_a_photo_outlined, color: muted)
                    : CargoPhoto(path: path, side: 64),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              locked ? 'The photo shows once you accept.' : 'Tap the photo to see it larger.',
              key: const ValueKey('freight-cargo-photo-note'),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ],
    );
  }
}

/// Proof of delivery on a freight request (0267): the driver's photos at
/// pickup and at drop-off and the sender's signature, each opening larger.
/// The sender, the driver and admins see it.
class FreightProofView extends StatelessWidget {
  const FreightProofView({super.key, required this.request});
  final RideRequest request;

  @override
  Widget build(BuildContext context) {
    final r = request;
    if (!r.isFreight) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    Widget proof(String key, String label, String? path, IconData icon) => SizedBox(
      width: 84,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Material(
          color: t.colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('freight-proof-$key'),
            onTap: path == null ? null : () => showCargoPhoto(context, path),
            child: SizedBox.square(
              dimension: 64,
              child: path == null ? Icon(icon, color: muted) : CargoPhoto(path: path, side: 64),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, textAlign: TextAlign.center, maxLines: 2, style: t.textTheme.labelSmall),
        Text(
          path == null ? 'Not yet' : 'Added',
          key: ValueKey('freight-proof-$key-state'),
          style: t.textTheme.labelSmall?.copyWith(color: muted),
        ),
      ]),
    );
    return Column(
      key: ValueKey('freight-proof-${r.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Proof of delivery', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          proof('pickup', 'At pickup', r.pickupProofPath, Icons.photo_camera_outlined),
          proof('dropoff', 'At drop-off', r.dropoffProofPath, Icons.photo_camera_outlined),
          proof('signature', 'Signature', r.signaturePath, Icons.draw_outlined),
        ]),
      ],
    );
  }
}

/// The time the driver has waited at pickup, ticking, with what it costs
/// past the free minutes (Ride Options by place, 0267).
class FreightWaitingTimer extends StatefulWidget {
  const FreightWaitingTimer({
    super.key,
    required this.since,
    required this.values,
    required this.money,
    this.clock = DateTime.now,
  });
  final DateTime since;
  final FreightPlaceValues values;
  final String Function(double) money;
  final DateTime Function() clock;

  @override
  State<FreightWaitingTimer> createState() => _FreightWaitingTimerState();
}

class _FreightWaitingTimerState extends State<FreightWaitingTimer> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final waited = widget.clock().difference(widget.since);
    final fee = freightWaitingFee(waited, widget.values);
    final over = waited.inMinutes >= widget.values.waitFreeMin;
    return Row(key: const ValueKey('freight-waiting-timer'), children: [
      Icon(Icons.timer_outlined, color: over ? t.colorScheme.error : t.colorScheme.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Waiting ${freightTimerText(waited)}',
            key: const ValueKey('freight-waiting-time'),
            style: t.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          Text(
            fee > 0
                ? '${freightWaitingRule(widget.values, widget.money)} · ${widget.money(fee)} so far'
                : freightWaitingRule(widget.values, widget.money),
            key: const ValueKey('freight-waiting-rule'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    ]);
  }
}

/// The sender signs with a finger; the strings of points as drawn.
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key, required this.onChanged, this.height = 180});
  final ValueChanged<List<List<Offset>>> onChanged;
  final double height;

  @override
  State<SignaturePad> createState() => SignaturePadState();
}

class SignaturePadState extends State<SignaturePad> {
  final _strokes = <List<Offset>>[];
  Size _size = Size.zero;

  void clear() {
    setState(_strokes.clear);
    widget.onChanged(const []);
  }

  /// The signature as a PNG, dark ink on white whatever the theme.
  Future<Uint8List?> png() async {
    if (_strokes.isEmpty || _size.isEmpty) return null;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & _size, Paint()..color = Colors.white);
    _SignaturePainter(_strokes, Colors.black).paint(canvas, _size);
    final image = await rec.endRecording().toImage(_size.width.ceil(), _size.height.ceil());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        _size = Size(c.maxWidth, widget.height);
        return Container(
          key: const ValueKey('signature-pad'),
          height: widget.height,
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.colorScheme.outlineVariant),
          ),
          child: GestureDetector(
            onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
            onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
            onPanEnd: (_) => widget.onChanged([for (final s in _strokes) List.of(s)]),
            child: CustomPaint(painter: _SignaturePainter(_strokes, t.colorScheme.onSurface), size: Size.infinite),
          ),
        );
      },
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes, this.ink);
  final List<List<Offset>> strokes;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = ink
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length == 1) canvas.drawCircle(s.first, 1.5, p..style = PaintingStyle.fill);
      p.style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < s.length; i++) {
        i == 0 ? path.moveTo(s[i].dx, s[i].dy) : path.lineTo(s[i].dx, s[i].dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => true;
}

/// Sign for the delivery: the pad, Clear and Save. The signature as a PNG,
/// or null when closed.
Future<Uint8List?> showSignatureSheet(BuildContext context) => showAppSheet<Uint8List>(id: 'ride.freight-signature',
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _SignatureSheet(),
);

class _SignatureSheet extends StatefulWidget {
  const _SignatureSheet();

  @override
  State<_SignatureSheet> createState() => _SignatureSheetState();
}

class _SignatureSheetState extends State<_SignatureSheet> {
  final _pad = GlobalKey<SignaturePadState>();
  bool _signed = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Sign for the delivery', textAlign: TextAlign.center, style: t.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Optional. Sign with your finger to confirm the cargo was delivered.',
          textAlign: TextAlign.center,
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        SignaturePad(key: _pad, onChanged: (s) => setState(() => _signed = s.isNotEmpty)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              key: const ValueKey('signature-clear'),
              onPressed: _signed ? () => _pad.currentState?.clear() : null,
              child: const Text('Clear'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              key: const ValueKey('signature-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _signed
                  ? () async {
                      final png = await _pad.currentState?.png();
                      if (context.mounted) Navigator.pop(context, png);
                    }
                  : null,
              child: const Text('Save'),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// The recipient's tracking link: each channel and how it went (admins).
class FreightNoticesView extends ConsumerWidget {
  const FreightNoticesView({super.key, required this.rideId});
  final String rideId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(freightNoticesProvider(rideId)).value ?? const [];
    if (rows.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    String label(Object? c) => c == 'whatsapp' ? 'WhatsApp' : 'SMS';
    return Column(key: const ValueKey('freight-notices'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Tracking link to the recipient', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      for (final r in rows)
        Text(
          '${label(r['channel'])}: ${r['status']}${r['error'] == null ? '' : ' (${r['error']})'}',
          style: t.textTheme.bodySmall,
        ),
    ]);
  }
}

/// The driver's part of a freight trip (0267): the waiting timer once
/// arrived, the photos at pickup and at drop-off, and, after pickup, asking
/// the sender to cancel (approved by itself if they don't answer).
class FreightDriverPanel extends ConsumerStatefulWidget {
  const FreightDriverPanel({super.key, required this.request, this.clock = DateTime.now});
  final RideRequest request;
  final DateTime Function() clock;

  @override
  ConsumerState<FreightDriverPanel> createState() => _FreightDriverPanelState();
}

class _FreightDriverPanelState extends ConsumerState<FreightDriverPanel> {
  String? _uploading;

  Future<void> _photo(String kind, String column) async {
    if (_uploading != null) return;
    final source = await choosePhotoSource(context, camera: ref.read(photoCameraAvailableProvider));
    if (source == null || !mounted) return;
    PickedPhoto? photo;
    try {
      photo = await ref.read(photoPickerProvider)(source);
    } catch (_) {
      if (mounted) showInfo(context, "Couldn't open the camera. Check that GET.ride may use it in Settings.");
      return;
    }
    if (photo == null || !mounted) return;
    final problem = ridePhotoProblem(photo.bytes.length);
    if (problem != null) return showInfo(context, problem);
    setState(() => _uploading = column);
    try {
      final path = await ref.read(freightProofUploadProvider)(photo.bytes, photo.name, kind);
      await ref.read(freightRepositoryProvider).setProof(widget.request.id, column, path);
      if (mounted) showInfo(context, 'Photo added.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  Future<void> _askCancel() async {
    final minutes = widget.request.isCourier
        ? (ref.read(courierConfigProvider).value ?? const CourierConfig()).cancelApproveMinutes
        : (ref.read(freightConfigProvider).value ?? const FreightConfig()).cancelApproveMinutes;
    final goods = widget.request.isCourier ? 'parcel is' : 'goods are';
    final ok = await showAppDialog<bool>(id: 'ride.freight-driver-cancel',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Ask the sender to cancel?'),
        content: Text(
          'The $goods on board, so the sender decides. If they don\'t answer in $minutes min, the request is '
          'cancelled.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep the trip')),
          FilledButton(
            key: const ValueKey('freight-driver-cancel-confirm'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Ask to cancel'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(rideRepositoryProvider).cancel(widget.request, reason: 'Driver asked to cancel after pickup', by: 'partner');
      if (mounted) showInfo(context, 'The sender has been asked.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final t = Theme.of(context);
    final places = ref.watch(rideOptionPlacesProvider).value ?? OptionPlaces.none;
    final place = RegionScope(
      country: '${r.raw['country'] ?? ''}'.trim(),
      state: '${r.raw['state'] ?? ''}'.trim(),
      city: '${r.raw['city'] ?? ''}'.trim(),
    );
    final values = freightPlaceValues(places, place, kind: r.isCourier ? DeliveryKind.courier : DeliveryKind.freight);
    String money(double v) => formatMoney(v, r.currency, v == v.roundToDouble() ? 0 : 2);
    final status = r.status;
    final asked = r.cancelRequestedAt != null && r.cancelRequestedBy == 'partner';
    Widget button(String key, String label, String kind, String column, bool done) => OutlinedButton.icon(
      key: ValueKey(key),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      onPressed: _uploading != null ? null : () => _photo(kind, column),
      icon: _uploading == column
          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(done ? Icons.check_circle_outline : Icons.photo_camera_outlined),
      label: Text(done ? '$label (again)' : label),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (status == RideStatus.arrived && r.arrivedAt != null) ...[
        FreightWaitingTimer(since: r.arrivedAt!, values: values, money: money, clock: widget.clock),
        const SizedBox(height: 8),
      ],
      if ((r.waitingFee ?? 0) > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Waiting ${r.waitingMinutes ?? 0} min: + ${money(r.waitingFee!)} on the fare',
            key: const ValueKey('freight-waiting-fee'),
            style: t.textTheme.bodySmall,
          ),
        ),
      FreightProofView(request: r),
      const SizedBox(height: 8),
      if (status == RideStatus.accepted || status == RideStatus.arrived)
        button('freight-proof-pickup-take', 'Take the pickup photo', 'proof-pickup', 'pickup_proof_path',
            r.pickupProofPath != null),
      if (status == RideStatus.onTrip) ...[
        button('freight-proof-dropoff-take', 'Take the drop-off photo', 'proof-dropoff', 'dropoff_proof_path',
            r.dropoffProofPath != null),
        const SizedBox(height: 8),
        if (asked)
          Text(
            'Waiting for the sender to answer your cancel request.',
            key: const ValueKey('freight-driver-cancel-asked'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          )
        else
          TextButton(
            key: const ValueKey('freight-driver-cancel'),
            onPressed: _askCancel,
            child: const Text('Ask the sender to cancel'),
          ),
      ],
    ]);
  }
}

/// The sender's part of a freight trip on the trip screen (0267): the proof
/// of delivery and, at drop-off, the optional signature.
class FreightSenderPanel extends ConsumerStatefulWidget {
  const FreightSenderPanel({super.key, required this.request});
  final RideRequest request;

  @override
  ConsumerState<FreightSenderPanel> createState() => _FreightSenderPanelState();
}

class _FreightSenderPanelState extends ConsumerState<FreightSenderPanel> {
  bool _saving = false;

  Future<void> _sign() async {
    final png = await showSignatureSheet(context);
    if (png == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final path = await ref.read(freightProofUploadProvider)(png, 'signature.png', 'signature');
      await ref.read(freightRepositoryProvider).setProof(widget.request.id, 'delivery_signature_path', path);
      if (mounted) showInfo(context, 'Thanks, your signature is saved.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final t = Theme.of(context);
    final canSign = r.status == RideStatus.arrived || r.status == RideStatus.onTrip || r.status == RideStatus.completed;
    return Card(
      key: const ValueKey('freight-sender-panel'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          // Courier (0268): the code for the recipient.
          if (r.isCourier) ...[
            CourierCodeCard(request: r),
            const SizedBox(height: 12),
          ],
          FreightProofView(request: r),
          if ((r.waitingFee ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The ${r.isCourier ? 'courier' : 'driver'} waited ${r.waitingMinutes ?? 0} min: + ${r.fareText(r.waitingFee)} on the fare',
                style: t.textTheme.bodySmall,
              ),
            ),
          if (canSign && r.signaturePath == null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('freight-sign'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: _saving ? null : _sign,
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Sign for the delivery'),
            ),
          ],
        ]),
      ),
    );
  }
}
