// Trip safety signals on screen (reliability Phase D4,
// lib/src/core/trip_safety.dart): the passenger's "Are you in the car?" /
// "Are you still on your trip?" banner, their lost item reports, and the
// driver's list of reports to answer.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/trip_safety.dart';
import '../data/models.dart';
import '../data/reliability_repository.dart';
import '../data/trip_safety_repository.dart';
import 'app_notice.dart';
import 'common.dart';
import 'page_style_host.dart';

/// Asks the passenger, mid-trip, the question the server flagged. "Get help"
/// runs [onHelp] (the trip screen's SOS).
class SafetyCheckBanner extends ConsumerStatefulWidget {
  const SafetyCheckBanner({super.key, required this.ride, required this.onHelp});

  final RideRequest ride;
  final VoidCallback onHelp;

  @override
  ConsumerState<SafetyCheckBanner> createState() => _SafetyCheckBannerState();
}

class _SafetyCheckBannerState extends ConsumerState<SafetyCheckBanner> {
  bool _busy = false;

  /// The flag answered on this phone, before the ride row catches up: a
  /// later flag still asks again.
  DateTime? _answeredFlag;

  DateTime? get _latestFlag => [
    widget.ride.startFlagAt,
    widget.ride.separatedAt,
  ].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

  Future<void> _ok() async {
    setState(() => _busy = true);
    try {
      await ref.read(tripSafetyRepositoryProvider).ok(widget.ride.id);
      if (mounted) setState(() => _answeredFlag = _latestFlag);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final ack = [
      r.safetyAckAt,
      _answeredFlag,
    ].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final ask = safetyAsk(
      onTrip: r.status == RideStatus.onTrip,
      startFlagAt: r.startFlagAt,
      separatedAt: r.separatedAt,
      ackAt: ack,
    );
    if (ask == null) return const SizedBox.shrink();
    final copy = safetyAskCopy(ask);
    final c = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('safety-check'),
      color: c.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.health_and_safety_outlined, color: c.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    copy.title,
                    style: TextStyle(color: c.onErrorContainer, fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(copy.body, style: TextStyle(color: c.onErrorContainer)),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const ValueKey('safety-help'),
                  style: TextButton.styleFrom(foregroundColor: c.onErrorContainer),
                  icon: const Icon(Icons.sos),
                  label: const Text('Get help'),
                  onPressed: widget.onHelp,
                ),
                FilledButton(key: const ValueKey('safety-ok'), onPressed: _busy ? null : _ok, child: Text(copy.ok)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// After a trip: "Left something behind?", with this trip's reports and
/// what the driver answered. Shows nothing once the window has passed or
/// the admin has it off.
class LostItemCard extends ConsumerWidget {
  const LostItemCard({super.key, required this.ride});
  final RideRequest ride;

  Future<void> _report(BuildContext context, WidgetRef ref) async {
    final text = await showAppDialog<String>(id: 'trip-safety.report', context: context, builder: (_) => const _LostItemDialog());
    if (text == null || !context.mounted) return;
    try {
      await ref.read(tripSafetyRepositoryProvider).reportLostItem(ride.id, text);
      ref.invalidate(rideLostItemsProvider(ride.id));
      if (context.mounted) {
        unawaited(showAppNotice(
          id: 'notice.trip-safety',
          context: context,
          message: 'Your driver has been told. You\'ll hear back here.',
          kind: NoticeKind.success,
        ));
      }
    } catch (e) {
      if (context.mounted) {
        unawaited(showAppNotice(
          id: 'notice.trip-safety',
          context: context,
          message: lostItemError(e),
          kind: NoticeKind.error,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(reliabilityProvider.select((s) => s.safety.lostItems));
    final canReport = canReportLostItem(
      enabled: enabled,
      completed: ride.status == RideStatus.completed,
      completedAt: ride.completedAt,
      now: DateTime.now(),
    );
    final items = ref.watch(rideLostItemsProvider(ride.id)).value ?? const <LostItem>[];
    if (!canReport && items.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('lost-item-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.backpack_outlined),
            title: const Text('Left something behind?'),
            subtitle: const Text('Tell your driver what you left in the car.'),
            trailing: canReport
                ? TextButton(
                    key: const ValueKey('lost-item-report'),
                    onPressed: () => _report(context, ref),
                    child: const Text('Report'),
                  )
                : null,
          ),
          for (final i in items)
            ListTile(
              key: ValueKey('lost-item-${i.id}'),
              dense: true,
              title: Text(i.description, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: i.driverNote == null ? null : Text('Driver: ${i.driverNote}'),
              trailing: Text(
                i.status.label,
                style: t.textTheme.labelMedium?.copyWith(
                  color: i.status == LostItemStatus.found || i.status == LostItemStatus.returned
                      ? t.colorScheme.primary
                      : t.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LostItemDialog extends StatefulWidget {
  const _LostItemDialog();

  @override
  State<_LostItemDialog> createState() => _LostItemDialogState();
}

class _LostItemDialogState extends State<_LostItemDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clean = cleanLostItemText(_text.text);
    return AlertDialog(
      title: const Text('What did you leave behind?'),
      content: TextField(
        key: const ValueKey('lost-item-text'),
        controller: _text,
        autofocus: true,
        maxLength: 500,
        maxLines: 3,
        minLines: 1,
        decoration: const InputDecoration(hintText: 'e.g. black umbrella, back seat'),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('lost-item-send'),
          onPressed: clean == null ? null : () => Navigator.pop(context, clean),
          child: const Text('Send'),
        ),
      ],
    );
  }
}

/// The driver's open lost item reports, each answered Found / Not found /
/// Returned. Shows nothing when there are none.
class DriverLostItemsCard extends ConsumerWidget {
  const DriverLostItemsCard({super.key});

  Future<void> _answer(BuildContext context, WidgetRef ref, LostItem item, LostItemStatus status) async {
    String? note;
    if (status != LostItemStatus.notFound) {
      note = await showAppDialog<String>(id: 'trip-safety.answer',
        context: context,
        builder: (_) => _NoteDialog(status: status),
      );
      if (note == null || !context.mounted) return;
    }
    try {
      await ref.read(tripSafetyRepositoryProvider).respondLostItem(item.id, status, note: note);
      ref.invalidate(driverLostItemsProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = (ref.watch(driverLostItemsProvider).value ?? const <LostItem>[])
        .where((i) => i.status == LostItemStatus.open || i.status == LostItemStatus.found)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final c = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('driver-lost-items'),
      color: c.tertiaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(Icons.backpack_outlined, color: c.onTertiaryContainer),
            title: Text(
              items.length == 1
                  ? 'A passenger left something behind'
                  : '${items.length} passengers left something behind',
              style: TextStyle(color: c.onTertiaryContainer, fontWeight: FontWeight.w700),
            ),
            subtitle: Text('Check your car and answer.', style: TextStyle(color: c.onTertiaryContainer)),
          ),
          for (final i in items)
            Padding(
              key: ValueKey('driver-lost-${i.id}'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(i.description, style: TextStyle(color: c.onTertiaryContainer)),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    children: [
                      if (i.status == LostItemStatus.open) ...[
                        TextButton(
                          key: ValueKey('driver-lost-none-${i.id}'),
                          style: TextButton.styleFrom(foregroundColor: c.onTertiaryContainer),
                          onPressed: () => _answer(context, ref, i, LostItemStatus.notFound),
                          child: const Text('Not found'),
                        ),
                        FilledButton.tonal(
                          key: ValueKey('driver-lost-found-${i.id}'),
                          onPressed: () => _answer(context, ref, i, LostItemStatus.found),
                          child: const Text('Found it'),
                        ),
                      ] else
                        FilledButton.tonal(
                          key: ValueKey('driver-lost-returned-${i.id}'),
                          onPressed: () => _answer(context, ref, i, LostItemStatus.returned),
                          child: const Text('Returned'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.status});
  final LostItemStatus status;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.status == LostItemStatus.found ? 'Found it' : 'Returned'),
    content: TextField(
      key: const ValueKey('driver-lost-note'),
      controller: _text,
      maxLength: 500,
      maxLines: 3,
      minLines: 1,
      decoration: InputDecoration(
        hintText: widget.status == LostItemStatus.found
            ? 'How can the passenger get it back? (optional)'
            : 'How was it returned? (optional)',
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('driver-lost-send'),
        onPressed: () => Navigator.pop(context, _text.text.trim()),
        child: const Text('Send'),
      ),
    ],
  );
}
