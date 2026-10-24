// Admin › Edit Partner › Change status (migration 0286): support asks the
// partner's phone to go online, go offline, link or unlink a vehicle; the
// card then shows the request live until the phone answers.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../../core/partner_remote_action.dart';
import '../../../data/partner_remote_repository.dart';
import '../../../widgets/page_style_host.dart';
import 'partner_live.dart';
import 'partner_screens.dart' show partnerFormDataProvider, partnerVehicleHoldersProvider;
import 'people_widgets.dart' show VehicleSelector;

/// One row of the sheet: an action offered, or greyed with why. [action] is
/// null for what the phone is never asked to do.
typedef RemoteChoice = ({RemoteAction? action, String label, IconData icon, String? why});

/// What the sheet offers for a driver who is [status] (null: not known).
List<RemoteChoice> remoteChoices(PartnerLive? status, {required bool hasVehicle}) {
  final online = status == PartnerLive.online || status == PartnerLive.offering;
  final onJob = status == PartnerLive.pickup || status == PartnerLive.waiting || status == PartnerLive.trip;
  final offline = status == PartnerLive.offline || status == PartnerLive.noVehicle;
  return [
    (
      action: RemoteAction.goOnline,
      label: RemoteAction.goOnline.label,
      icon: Icons.toggle_on_outlined,
      why: online ? 'Already online' : (onJob ? 'On a job already' : null),
    ),
    (
      action: RemoteAction.goOffline,
      label: RemoteAction.goOffline.label,
      icon: Icons.toggle_off_outlined,
      why: offline ? 'Already offline' : null,
    ),
    (action: RemoteAction.linkVehicle, label: RemoteAction.linkVehicle.label, icon: Icons.directions_car_outlined, why: null),
    (
      action: RemoteAction.unlinkVehicle,
      label: RemoteAction.unlinkVehicle.label,
      icon: Icons.link_off,
      why: hasVehicle ? null : 'No vehicle linked',
    ),
    (action: null, label: 'Start trip', icon: Icons.play_circle_outline, why: "Needs the rider's code"),
    (action: null, label: 'End a metered hire', icon: Icons.speed, why: 'Must be ended on the meter'),
  ];
}

/// The words for a request the server refused.
String remoteRequestError(Object e) {
  if (e is PostgrestException && e.message.trim().isNotEmpty) return e.message.trim();
  return "Couldn't send it. Try again.";
}

/// The partner's latest request, re-read by the card every 3 s while it is
/// open.
final partnerRemoteStatusProvider = FutureProvider.autoDispose.family<RemoteActionRequest?, String>(
    (ref, uid) => ref.watch(partnerRemoteRepositoryProvider).status(uid));

/// Opens the sheet; the request made, or null.
Future<RemoteActionRequest?> showPartnerRemoteSheet(
  BuildContext context, {
  required String userId,
  required PartnerLive? status,
  required bool hasVehicle,
  required bool Function(Map<String, dynamic>) isOwn,
}) =>
    showAppSheet<RemoteActionRequest>(
      id: 'partner-remote.change-status',
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PartnerRemoteSheet(userId: userId, status: status, hasVehicle: hasVehicle, isOwn: isOwn),
    );

/// The sheet: the actions, greyed with why where they can't be asked, and
/// the vehicle picker (the partner's own first, another driver's only while
/// that driver is offline) for Link vehicle.
class PartnerRemoteSheet extends ConsumerStatefulWidget {
  const PartnerRemoteSheet({
    super.key,
    required this.userId,
    required this.status,
    required this.hasVehicle,
    required this.isOwn,
  });
  final String userId;
  final PartnerLive? status;
  final bool hasVehicle;
  final bool Function(Map<String, dynamic>) isOwn;

  @override
  ConsumerState<PartnerRemoteSheet> createState() => _PartnerRemoteSheetState();
}

class _PartnerRemoteSheetState extends ConsumerState<PartnerRemoteSheet> {
  bool _linking = false;
  bool _sending = false;
  String? _error;

  Future<void> _send(RemoteAction a, {String? vehicleId}) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final r = await ref.read(partnerRemoteRepositoryProvider).request(widget.userId, a, vehicleId: vehicleId);
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = remoteRequestError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('Change status', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              "The driver's phone does it with its own checks and says how it went.",
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            if (_sending) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!, key: const ValueKey('remote-error'), style: TextStyle(color: t.colorScheme.error)),
              ),
            if (_linking) ..._picker(context) else ..._choices(context),
          ]),
        ),
      ),
    );
  }

  List<Widget> _choices(BuildContext context) => [
        for (final c in remoteChoices(widget.status, hasVehicle: widget.hasVehicle))
          ListTile(
            key: ValueKey('remote-${c.action?.wire ?? c.label}'),
            contentPadding: EdgeInsets.zero,
            enabled: c.action != null && c.why == null && !_sending,
            leading: Icon(c.icon),
            title: Text(c.label),
            subtitle: c.why == null ? null : Text(c.why!),
            onTap: c.action == null || c.why != null || _sending
                ? null
                : () => c.action == RemoteAction.linkVehicle
                    ? setState(() => _linking = true)
                    : _send(c.action!),
          ),
      ];

  List<Widget> _picker(BuildContext context) {
    final data = ref.watch(partnerFormDataProvider);
    final holders = ref.watch(partnerVehicleHoldersProvider(widget.userId)).value;
    return [
      Row(children: [
        IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: _sending ? null : () => setState(() => _linking = false),
        ),
        Expanded(child: Text('Link vehicle', style: Theme.of(context).textTheme.titleSmall)),
      ]),
      switch (data) {
        AsyncData(:final value) => VehicleSelector(
            vehicles: value.vehicles,
            selected: null,
            enabled: !_sending,
            isOwn: widget.isOwn,
            holders: holders,
            onChanged: (v) {
              final id = '${v?['id'] ?? ''}';
              if (id.isNotEmpty) _send(RemoteAction.linkVehicle, vehicleId: id);
            },
          ),
        AsyncError() => const Padding(padding: EdgeInsets.all(12), child: Text("Couldn't load the vehicles.")),
        _ => const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
      },
    ];
  }
}

/// The colour of a request's line, light or dark.
Color remoteLineColor(RemoteLineKind k, ThemeData t) {
  final dark = t.brightness == Brightness.dark;
  return switch (k) {
    RemoteLineKind.done => dark ? const Color(0xFF5FD38F) : const Color(0xFF1F8A4C),
    RemoteLineKind.refused => t.colorScheme.error,
    RemoteLineKind.waiting => t.colorScheme.primary,
    RemoteLineKind.expired => t.colorScheme.onSurfaceVariant,
  };
}

/// The request on the card: waiting, done, refused with the phone's
/// reason, or no answer.
class PartnerRemoteLine extends StatelessWidget {
  const PartnerRemoteLine({super.key, required this.request, this.now});
  final RemoteActionRequest request;

  /// Clock override for tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final line = remoteRequestLine(request, now: now);
    final c = remoteLineColor(line.kind, t);
    final plate = request.vehiclePlate;
    final asked = request.action == RemoteAction.linkVehicle && plate != null
        ? '${request.action.label} $plate'
        : request.action.label;
    return Row(key: ValueKey('remote-line-${line.kind.name}'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox.square(
        dimension: 20,
        child: switch (line.kind) {
          RemoteLineKind.waiting => Padding(
              padding: const EdgeInsets.all(3),
              child: CircularProgressIndicator(strokeWidth: 2, color: c),
            ),
          RemoteLineKind.done => Icon(Icons.check_circle_outline, size: 20, color: c),
          RemoteLineKind.refused => Icon(Icons.block, size: 20, color: c),
          RemoteLineKind.expired => Icon(Icons.schedule, size: 20, color: c),
        },
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Asked: $asked', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          Text(line.text, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
        ]),
      ),
    ]);
  }
}
