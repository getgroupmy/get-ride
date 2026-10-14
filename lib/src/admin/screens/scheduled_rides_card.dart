// Admin → App Settings → Scheduled rides (migration 0189): booking window,
// the scheduling fee (fixed + percentage), free cancellation and the late
// fee, and how drivers get bookings (pre-accept ahead, or released before
// pickup). Below them, the bookings still to come.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/scheduled_rides.dart';
import '../../data/live_tables.dart';
import '../../data/scheduled_ride_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

final adminScheduledRidesProvider = FutureProvider.autoDispose<List<ScheduledRide>>((ref) {
  ref.watchLive('scheduled_rides');
  return ref.watch(scheduledRideRepositoryProvider).all();
});

class ScheduledRidesCard extends ConsumerWidget {
  const ScheduledRidesCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('scheduled-rides-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Scheduled rides', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Riders book ahead, for themselves or someone else. A booking becomes a ride before pickup; if its '
              'driver cancels, it goes back to other drivers and the rider is told.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            AsyncView(
              value: ref.watch(scheduledRidesConfigProvider),
              onRetry: () => ref.invalidate(scheduledRidesConfigProvider),
              data: (c) => _ConfigForm(key: ValueKey(c), stored: c, canEdit: canEdit),
            ),
            const Divider(height: 32),
            Text('Upcoming bookings', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            AsyncView(
              value: ref.watch(adminScheduledRidesProvider),
              onRetry: () => ref.invalidate(adminScheduledRidesProvider),
              data: (rides) => rides.isEmpty
                  ? Text('None.', style: t.textTheme.bodySmall)
                  : Column(children: [for (final r in rides) _BookingTile(ride: r)]),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfigForm extends ConsumerStatefulWidget {
  const _ConfigForm({super.key, required this.stored, required this.canEdit});

  final ScheduledRidesConfig stored;
  final bool canEdit;

  @override
  ConsumerState<_ConfigForm> createState() => _ConfigFormState();
}

class _ConfigFormState extends ConsumerState<_ConfigForm> {
  late bool _enabled = widget.stored.enabled;
  late bool _advance = widget.stored.advance;
  late bool _feeToDriver = widget.stored.feeToDriver;
  late final _lead = TextEditingController(text: '${widget.stored.minLeadMinutes}');
  late final _days = TextEditingController(text: '${widget.stored.maxDaysAhead}');
  late final _feeFixed = TextEditingController(text: _plain(widget.stored.feeFixed));
  late final _feePercent = TextEditingController(text: _plain(widget.stored.feePercent));
  late final _freeCancel = TextEditingController(text: '${widget.stored.freeCancelMinutes}');
  late final _lateFee = TextEditingController(text: _plain(widget.stored.lateCancelFee));
  late final _release = TextEditingController(text: '${widget.stored.releaseMinutes}');
  late final _reminder = TextEditingController(text: '${widget.stored.reminderMinutes}');

  static String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  List<TextEditingController> get _fields => [
    _lead,
    _days,
    _feeFixed,
    _feePercent,
    _freeCancel,
    _lateFee,
    _release,
    _reminder,
  ];

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  ScheduledRidesConfig? _draft() {
    int? i(TextEditingController c) => int.tryParse(c.text.trim());
    double? d(TextEditingController c) => double.tryParse(c.text.trim());
    final values = [
      i(_lead),
      i(_days),
      d(_feeFixed),
      d(_feePercent),
      i(_freeCancel),
      d(_lateFee),
      i(_release),
      i(_reminder),
    ];
    if (values.contains(null)) return null;
    return ScheduledRidesConfig(
      enabled: _enabled,
      minLeadMinutes: i(_lead)!,
      maxDaysAhead: i(_days)!,
      feeFixed: d(_feeFixed)!,
      feePercent: d(_feePercent)!,
      feeToDriver: _feeToDriver,
      freeCancelMinutes: i(_freeCancel)!,
      lateCancelFee: d(_lateFee)!,
      advance: _advance,
      releaseMinutes: i(_release)!,
      reminderMinutes: i(_reminder)!,
    );
  }

  Future<void> _save() async {
    final c = _draft();
    final problem = c == null ? 'Every field needs a number.' : c.problem;
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    final saved = await runAdminAction(
      context,
      () => ref.read(scheduledRideRepositoryProvider).saveConfig(c!),
      success: 'Scheduled rides saved',
    );
    if (saved && mounted) ref.invalidate(scheduledRidesConfigProvider);
  }

  Widget _number(String key, TextEditingController c, String label, String hint, {bool decimal = false}) => SizedBox(
    width: 220,
    child: TextField(
      key: ValueKey('scheduled-$key'),
      controller: c,
      enabled: widget.canEdit,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      decoration: InputDecoration(labelText: label, helperText: hint, helperMaxLines: 2),
      onChanged: (_) => setState(() {}),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edit = widget.canEdit;
    final draft = _draft();
    final example = draft == null ? null : schedulingFee(20, draft);
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(title, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('scheduled-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Scheduled rides on'),
          subtitle: const Text('Off: the "Schedule for later" row is hidden and no new bookings are taken.'),
          value: _enabled,
          onChanged: edit ? (v) => setState(() => _enabled = v) : null,
        ),
        section('Booking window'),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _number('lead', _lead, 'Soonest pickup (minutes ahead)', '5–1440'),
            _number('days', _days, 'Furthest ahead (days)', '1–30'),
            _number('reminder', _reminder, 'Rider reminder (minutes before)', '0: no reminder'),
          ],
        ),
        section('Scheduling fee'),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _number('fee-fixed', _feeFixed, 'Fixed amount', '0–1000', decimal: true),
            _number('fee-percent', _feePercent, 'Percentage of the fare', '0–100', decimal: true),
          ],
        ),
        if (example != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'On a ${formatMoney(20)} ride: ${formatMoney(example)} fee.',
              key: const ValueKey('scheduled-fee-example'),
              style: t.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          key: const ValueKey('scheduled-fee-to'),
          segments: const [
            ButtonSegment(value: false, label: Text('Platform keeps it')),
            ButtonSegment(value: true, label: Text('Driver keeps it')),
          ],
          selected: {_feeToDriver},
          onSelectionChanged: edit ? (v) => setState(() => _feeToDriver = v.first) : null,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _feeToDriver
                ? 'The driver is paid the fee with the fare.'
                : 'The driver collects it with the fare; it is taken back from their GET credit after the trip.',
            style: t.textTheme.bodySmall,
          ),
        ),
        section('Cancellation'),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _number('free-cancel', _freeCancel, 'Free until (minutes before pickup)', 'e.g. 60'),
            _number('late-fee', _lateFee, 'Late cancellation fee', '0: free at any time', decimal: true),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            "Taken from the rider's GET wallet; without the balance it is owed and added to their next ride "
            '(and taken back from that driver, who collects it).',
            style: t.textTheme.bodySmall,
          ),
        ),
        section('How drivers get bookings'),
        SegmentedButton<bool>(
          key: const ValueKey('scheduled-mode'),
          segments: const [
            ButtonSegment(value: true, label: Text('Pre-accept ahead')),
            ButtonSegment(value: false, label: Text('Release before pickup')),
          ],
          selected: {_advance},
          onSelectionChanged: edit ? (v) => setState(() => _advance = v.first) : null,
        ),
        const SizedBox(height: 8),
        _number('release', _release, 'Release (minutes before pickup)', '5–180'),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _advance
                ? 'Drivers see bookings ahead and take them. At release the ride goes to that driver; a booking '
                      'nobody took goes to every driver nearby.'
                : 'Drivers first see a booking at release, as an ordinary request.',
            style: t.textTheme.bodySmall,
          ),
        ),
        if (edit) ...[
          const SizedBox(height: 12),
          BusyButton.filled(
            key: const ValueKey('scheduled-save'),
            onPressed: draft == widget.stored ? null : _save,
            icon: const Icon(Icons.save_outlined),
            child: const Text('Save scheduled rides'),
          ),
        ],
      ],
    );
  }
}

class _BookingTile extends StatelessWidget {
  const _BookingTile({required this.ride});

  final ScheduledRide ride;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListTile(
      key: ValueKey('admin-scheduled-${ride.id}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.event_outlined),
      title: Text(
        '${DateFormat('EEE d MMM, HH:mm').format(ride.pickupAt)} · ${formatMoney(ride.total, ride.currency ?? 'MYR')}',
      ),
      subtitle: Text(
        [
          '${ride.pickupAddress ?? 'Pickup'} → ${ride.dropAddress ?? 'Destination'}',
          if (ride.bookedForName != null) 'For ${ride.bookedForName}',
          switch (ride.status) {
            ScheduledStatus.scheduled => 'No driver yet',
            ScheduledStatus.assigned => 'Driver confirmed',
            ScheduledStatus.released => 'Released',
            _ => ride.status.name,
          },
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: t.textTheme.bodySmall,
      ),
    );
  }
}
