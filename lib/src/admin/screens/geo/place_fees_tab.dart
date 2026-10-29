// Admin → Airport Areas → Fees, and a Multi-Gate place's Fees tab
// (migration 0324): the place's list of pickup / drop-off fees, each with
// its editor, and the place fee settings shared by every place.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/place_fees.dart';
import '../../../data/place_fees_repository.dart';
import '../../../widgets/date_boxes.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../widgets/admin_widgets.dart';
import 'airport_tabs.dart' show AirportNote, AirportSwitch;

/// A place's fees: the list (name, which end, amount, when, on/off, move up
/// or down), Add fee, and the shared settings above them.
class PlaceFeesTab extends ConsumerWidget {
  const PlaceFeesTab({
    super.key,
    required this.areaId,
    required this.canEdit,
    this.services = const [],
    this.currency = 'MYR',
    this.ready = true,
    this.noun = 'airport',
  });

  /// The airport's or place's area id (airport_areas).
  final String areaId;
  final bool canEdit;

  /// The vehicle services' names, for the editor's choice.
  final List<String> services;
  final String currency;

  /// False while a place has no boundary: nothing here works yet.
  final bool ready;
  final String noun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final all = ref.watch(placeFeesProvider).value ?? const <PlaceFee>[];
    final fees = placeFeesFor(all, areaId);
    final edit = canEdit && ready;
    String money(double v) => formatMoney(v, currency);
    final repo = ref.read(placeFeesRepositoryProvider);

    Future<void> open([PlaceFee? fee]) async {
      final saved = await showPlaceFeeEditor(
        context,
        fee ?? PlaceFee(areaId: areaId, name: '', amount: 5, sortOrder: nextPlaceFeeOrder(fees)),
        services: services,
        currency: currency,
        canEdit: edit,
        onDelete: fee?.id == null || !edit
            ? null
            : () => runAdminAction(context, () => repo.delete(fee!.id!), success: 'Fee removed'),
      );
      if (saved == null || !context.mounted) return;
      final ok = await runAdminAction(context, () => repo.save(saved), success: 'Fee saved');
      if (ok) ref.invalidate(placeFeesProvider);
    }

    Future<void> move(PlaceFee f, int dir) async {
      final orders = reorderPlaceFees(fees, f.id ?? '', dir);
      if (orders.isEmpty) return;
      final ok = await runAdminAction(context, () => repo.reorder(orders));
      if (ok) ref.invalidate(placeFeesProvider);
    }

    return ListView(
      key: const ValueKey('place-fees-tab'),
      padding: const EdgeInsets.all(16),
      children: [
        PlaceFeeSettingsCard(canEdit: canEdit, currency: currency),
        const SizedBox(height: 12),
        AirportNote(
          'Each fee is added to the fare of a ride that starts or ends inside this $noun, and shown to the rider '
          'before they book. Riders see the name; the note shows in the fare details.',
        ),
        if (!ready)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Switch the boundary on first (Boundary tab).',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
            ),
          ),
        const SizedBox(height: 12),
        if (fees.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No fees yet.', key: const ValueKey('place-fees-empty'), style: t.textTheme.bodyMedium),
          ),
        for (final (i, f) in fees.indexed)
          Card(
            key: ValueKey('place-fee-${f.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: () => open(f),
              title: Text(f.name.isEmpty ? 'Fee' : f.name),
              subtitle: Text(
                [
                  placeFeeEndLabel(f.appliesTo),
                  f.amountText(money),
                  f.whenText(date: formatStoredDateForUser),
                  if (f.services.isNotEmpty) f.services.join(', '),
                  placeFeeGoesToLabel(f.goesTo),
                ].join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (edit) ...[
                    IconButton(
                      key: ValueKey('place-fee-up-${f.id}'),
                      tooltip: 'Move up',
                      onPressed: i == 0 ? null : () => move(f, -1),
                      icon: const Icon(Icons.arrow_upward, size: 20),
                    ),
                    IconButton(
                      key: ValueKey('place-fee-down-${f.id}'),
                      tooltip: 'Move down',
                      onPressed: i == fees.length - 1 ? null : () => move(f, 1),
                      icon: const Icon(Icons.arrow_downward, size: 20),
                    ),
                  ],
                  Switch(
                    key: ValueKey('place-fee-on-${f.id}'),
                    value: f.enabled,
                    onChanged: !edit || f.id == null
                        ? null
                        : (v) async {
                            final ok = await runAdminAction(context, () => repo.setEnabled(f.id!, v));
                            if (ok) ref.invalidate(placeFeesProvider);
                          },
                  ),
                ],
              ),
            ),
          ),
        if (edit)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const ValueKey('place-fee-add'),
              onPressed: () => open(),
              icon: const Icon(Icons.add),
              label: const Text('Add fee'),
            ),
          ),
      ],
    );
  }
}

/// Opens a fee's editor; the fee as saved, or null when cancelled.
Future<PlaceFee?> showPlaceFeeEditor(
  BuildContext context,
  PlaceFee fee, {
  List<String> services = const [],
  String currency = 'MYR',
  bool canEdit = true,
  Future<bool> Function()? onDelete,
}) => showAppSheet<PlaceFee>(
  id: 'place-fees.editor',
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (c) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
    child: PlaceFeeEditor(
      fee: fee,
      services: services,
      currency: currency,
      canEdit: canEdit,
      onSave: (f) => Navigator.pop(c, f),
      onCancel: () => Navigator.pop(c),
      onDelete: onDelete == null
          ? null
          : () async {
              if (!await confirm(c, 'Remove fee', 'Remove ${fee.name}? Rides booked already keep it.', ok: 'Remove')) {
                return;
              }
              if (await onDelete() && c.mounted) Navigator.pop(c);
            },
    ),
  ),
);

/// Every field of one fee.
class PlaceFeeEditor extends StatefulWidget {
  const PlaceFeeEditor({
    super.key,
    required this.fee,
    required this.onSave,
    this.onCancel,
    this.onDelete,
    this.services = const [],
    this.currency = 'MYR',
    this.canEdit = true,
  });

  final PlaceFee fee;
  final ValueChanged<PlaceFee> onSave;
  final VoidCallback? onCancel, onDelete;
  final List<String> services;
  final String currency;
  final bool canEdit;

  @override
  State<PlaceFeeEditor> createState() => _PlaceFeeEditorState();
}

class _PlaceFeeEditorState extends State<PlaceFeeEditor> {
  late PlaceFee _f = widget.fee;
  late final _name = TextEditingController(text: widget.fee.name);
  late final _note = TextEditingController(text: widget.fee.riderNote);
  late final _amount = TextEditingController(text: _num(widget.fee.amount));
  late final _min = TextEditingController(text: _num(widget.fee.minAmount));
  late final _max = TextEditingController(text: _num(widget.fee.maxAmount));
  late final _from = TextEditingController(text: widget.fee.dateFrom ?? '');
  late final _to = TextEditingController(text: widget.fee.dateTo ?? '');
  String? _error;

  static String _num(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  @override
  void dispose() {
    for (final c in [_name, _note, _amount, _min, _max, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(PlaceFee f) => setState(() {
    _f = f;
    _error = null;
  });

  double? _parse(TextEditingController c) {
    final s = c.text.trim();
    return s.isEmpty ? null : double.tryParse(s);
  }

  Future<void> _pickTime(bool from) async {
    final now = from ? _f.timeFrom : _f.timeTo;
    final parts = (now ?? (from ? '08:00' : '20:00')).split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked == null || !mounted) return;
    final v = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    _set(from ? _f.copyWith(timeFrom: () => v, timeTo: () => _f.timeTo ?? v) : _f.copyWith(timeTo: () => v, timeFrom: () => _f.timeFrom ?? v));
  }

  void _save() {
    String? date(TextEditingController c) {
      final s = c.text.trim();
      return s.isEmpty ? null : placeFeeDateOf(s);
    }

    if ((_from.text.trim().isNotEmpty && date(_from) == null) || (_to.text.trim().isNotEmpty && date(_to) == null)) {
      setState(() => _error = 'Finish the dates, or clear them.');
      return;
    }
    final f = _f.copyWith(
      name: _name.text.trim(),
      riderNote: _note.text.trim(),
      amount: _parse(_amount) ?? 0,
      minAmount: () => _f.percent ? _parse(_min) : null,
      maxAmount: () => _f.percent ? _parse(_max) : null,
      dateFrom: () => date(_from),
      dateTo: () => date(_to),
    );
    final problem = f.problem;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    widget.onSave(f);
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = widget.canEdit;
    final f = _f;
    final numbers = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
    final allServices = {...widget.services, ...f.services}.toList();
    return ListView(
      key: const ValueKey('place-fee-editor'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Text(widget.fee.id == null ? 'Add fee' : 'Edit fee', style: t.textTheme.titleLarge),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('place-fee-name'),
          controller: _name,
          enabled: on,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Name riders see', hintText: 'e.g. KLIA kerbside fee'),
        ),
        TextField(
          key: const ValueKey('place-fee-note'),
          controller: _note,
          enabled: on,
          maxLength: 240,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Note for riders (optional)', hintText: 'What the fee is for'),
        ),
        _label(context, 'Charged for'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in PlaceFeeEnd.values)
              ChoiceChip(
                key: ValueKey('place-fee-end-${e.name}'),
                label: Text(placeFeeEndLabel(e)),
                selected: f.appliesTo == e,
                onSelected: on ? (_) => _set(f.copyWith(appliesTo: e)) : null,
              ),
          ],
        ),
        _label(context, 'Amount'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<PlaceFeeAmountKind>(
              key: const ValueKey('place-fee-kind'),
              segments: [
                ButtonSegment(value: PlaceFeeAmountKind.fixed, label: Text('Fixed (${widget.currency})')),
                const ButtonSegment(value: PlaceFeeAmountKind.percent, label: Text('% of fare')),
              ],
              selected: {f.amountKind},
              onSelectionChanged: on ? (s) => _set(f.copyWith(amountKind: s.first)) : null,
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: const ValueKey('place-fee-amount'),
                controller: _amount,
                enabled: on,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: numbers,
                decoration: InputDecoration(labelText: f.percent ? 'Percent' : 'Amount', isDense: true),
              ),
            ),
            if (f.percent) ...[
              SizedBox(
                width: 120,
                child: TextField(
                  key: const ValueKey('place-fee-min'),
                  controller: _min,
                  enabled: on,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: numbers,
                  decoration: InputDecoration(labelText: 'At least (${widget.currency})', isDense: true),
                ),
              ),
              SizedBox(
                width: 120,
                child: TextField(
                  key: const ValueKey('place-fee-max'),
                  controller: _max,
                  enabled: on,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: numbers,
                  decoration: InputDecoration(labelText: 'At most (${widget.currency})', isDense: true),
                ),
              ),
            ],
          ],
        ),
        _label(context, 'Vehicle services'),
        Text(
          f.services.isEmpty ? 'Every vehicle service' : 'Only: ${f.services.join(', ')}',
          key: const ValueKey('place-fee-services-text'),
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        ListSearchFilter(
          count: allServices.length,
          hint: 'Search services',
          fieldKey: const ValueKey('place-fee-services-search'),
          builder: (context, q) => Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in allServices)
                if (q.isEmpty || s.toLowerCase().contains(q.toLowerCase()))
                  FilterChip(
                    key: ValueKey('place-fee-service-$s'),
                    label: Text(s),
                    selected: f.services.contains(s),
                    onSelected: on
                        ? (v) => _set(f.copyWith(services: v ? [...f.services, s] : [for (final x in f.services) if (x != s) x]))
                        : null,
                  ),
            ],
          ),
        ),
        _label(context, 'Days'),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final d in placeFeeAllDays)
              FilterChip(
                key: ValueKey('place-fee-day-$d'),
                label: Text(placeFeeDayNames[d]),
                selected: f.days.contains(d),
                onSelected: on
                    ? (v) => _set(f.copyWith(days: v ? ([...f.days, d]..sort()) : [for (final x in f.days) if (x != d) x]))
                    : null,
              ),
          ],
        ),
        _label(context, 'Hours'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('place-fee-time-from'),
              onPressed: on ? () => _pickTime(true) : null,
              icon: const Icon(Icons.schedule, size: 18),
              label: Text('From ${f.timeFrom ?? '--:--'}'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('place-fee-time-to'),
              onPressed: on ? () => _pickTime(false) : null,
              icon: const Icon(Icons.schedule, size: 18),
              label: Text('To ${f.timeTo ?? '--:--'}'),
            ),
            if (f.timeFrom != null || f.timeTo != null)
              TextButton(
                key: const ValueKey('place-fee-all-day'),
                onPressed: on ? () => _set(f.copyWith(timeFrom: () => null, timeTo: () => null)) : null,
                child: const Text('All day'),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            f.timeFrom == null
                ? 'All day. Set both times for part of the day; a "to" before the "from" runs past midnight.'
                : (f.timeTo!.compareTo(f.timeFrom!) < 0
                      ? 'Runs past midnight, on the days it starts.'
                      : 'In the place fee settings\' time zone.'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        _label(context, 'Dates (optional)'),
        DateBoxesField(key: const ValueKey('place-fee-date-from'), label: 'First day', controller: _from, enabled: on),
        const SizedBox(height: 8),
        DateBoxesField(key: const ValueKey('place-fee-date-to'), label: 'Last day', controller: _to, enabled: on),
        const SizedBox(height: 8),
        AirportSwitch(
          title: 'A stop here counts like a drop-off',
          subtitle: 'Each stop inside the place is charged too',
          value: f.countStops,
          onChanged: on ? (v) => _set(f.copyWith(countStops: v)) : null,
        ),
        _label(context, 'Goes to'),
        Wrap(
          spacing: 8,
          children: [
            for (final g in PlaceFeeGoesTo.values)
              ChoiceChip(
                key: ValueKey('place-fee-goes-${g.name}'),
                label: Text(placeFeeGoesToLabel(g)),
                selected: f.goesTo == g,
                onSelected: on ? (_) => _set(f.copyWith(goesTo: g)) : null,
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            switch (f.goesTo) {
              PlaceFeeGoesTo.driver => "The driver's earning, in the commission base.",
              PlaceFeeGoesTo.platform => "The driver collects it; it is taken back from the driver's GET.credit.",
              PlaceFeeGoesTo.pass => 'Collected and passed on, like a toll: not an earning, not commissioned.',
            },
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        AirportSwitch(
          title: 'On',
          subtitle: 'Off: kept, but not charged',
          value: f.enabled,
          onChanged: on ? (v) => _set(f.copyWith(enabled: v)) : null,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, key: const ValueKey('place-fee-error'), style: TextStyle(color: t.colorScheme.error)),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (widget.onDelete != null)
              TextButton(
                key: const ValueKey('place-fee-delete'),
                onPressed: widget.onDelete,
                child: Text('Remove', style: TextStyle(color: t.colorScheme.error)),
              ),
            const Spacer(),
            TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('place-fee-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: on ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The settings every place's fees share, as a card that opens them.
class PlaceFeeSettingsCard extends ConsumerWidget {
  const PlaceFeeSettingsCard({super.key, required this.canEdit, this.currency = 'MYR'});

  final bool canEdit;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(placeFeeSettingsProvider).value ?? PlaceFeeSettings.defaults;
    return Card(
      key: const ValueKey('place-fee-settings-card'),
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.tune),
        title: const Text('Place fee settings'),
        subtitle: Text(
          [
            s.lockScheduled ? 'Booked for later: fee locked at booking' : 'Booked for later: fee at pickup',
            s.timeZone,
            s.maxTotal == null ? 'No most per ride' : 'At most ${formatMoney(s.maxTotal, currency)} per ride',
          ].join(' · '),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final saved = await showAppSheet<PlaceFeeSettings>(
            id: 'place-fees.settings',
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            showDragHandle: true,
            builder: (c) => Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
              child: PlaceFeeSettingsForm(
                settings: s,
                currency: currency,
                canEdit: canEdit,
                onSave: (v) => Navigator.pop(c, v),
                onCancel: () => Navigator.pop(c),
              ),
            ),
          );
          if (saved == null || !context.mounted) return;
          final ok = await runAdminAction(
            context,
            () => ref.read(placeFeesRepositoryProvider).saveSettings(saved),
            success: 'Place fee settings saved',
          );
          if (ok) ref.invalidate(placeFeeSettingsProvider);
        },
      ),
    );
  }
}

/// The IANA time zones offered first; any other can be typed.
const placeFeeTimeZones = [
  'Asia/Kuala_Lumpur', 'Asia/Singapore', 'Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura', 'Asia/Bangkok',
  'Asia/Ho_Chi_Minh', 'Asia/Manila', 'Asia/Brunei', 'Asia/Phnom_Penh', 'Asia/Yangon', 'Asia/Dhaka',
  'Asia/Kolkata', 'Asia/Karachi', 'Asia/Dubai', 'Asia/Riyadh', 'Asia/Qatar', 'Asia/Hong_Kong', 'Asia/Shanghai',
  'Asia/Taipei', 'Asia/Seoul', 'Asia/Tokyo', 'Australia/Perth', 'Australia/Sydney', 'Pacific/Auckland',
  'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Istanbul', 'Africa/Cairo', 'Africa/Lagos',
  'Africa/Nairobi', 'Africa/Johannesburg', 'America/New_York', 'America/Chicago', 'America/Denver',
  'America/Los_Angeles', 'America/Sao_Paulo', 'America/Mexico_City', 'UTC',
];

/// Every value of the place fee settings.
class PlaceFeeSettingsForm extends StatefulWidget {
  const PlaceFeeSettingsForm({
    super.key,
    required this.settings,
    required this.onSave,
    this.onCancel,
    this.currency = 'MYR',
    this.canEdit = true,
  });

  final PlaceFeeSettings settings;
  final ValueChanged<PlaceFeeSettings> onSave;
  final VoidCallback? onCancel;
  final String currency;
  final bool canEdit;

  @override
  State<PlaceFeeSettingsForm> createState() => _PlaceFeeSettingsFormState();
}

class _PlaceFeeSettingsFormState extends State<PlaceFeeSettingsForm> {
  late PlaceFeeSettings _s = widget.settings;
  late final _zone = TextEditingController(text: widget.settings.timeZone);
  late final _badge = TextEditingController(text: widget.settings.badgeText);
  late final _hint = TextEditingController(text: widget.settings.addressHintText);
  late final _cap = TextEditingController(
    text: widget.settings.maxTotal == null ? '' : widget.settings.maxTotal!.toStringAsFixed(2),
  );
  String? _error;

  @override
  void dispose() {
    for (final c in [_zone, _badge, _hint, _cap]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickZone() async {
    final z = await showSearchPicker<String>(
      context,
      title: 'Time zone',
      selected: _zone.text.trim(),
      choices: [for (final z in placeFeeTimeZones) (value: z, label: z.replaceAll('_', ' '), subtitle: z, leading: null)],
    );
    if (z != null && mounted) setState(() => _zone.text = z);
  }

  void _save() {
    final capText = _cap.text.trim();
    final cap = capText.isEmpty ? null : double.tryParse(capText);
    if (capText.isNotEmpty && cap == null) {
      setState(() => _error = 'Enter the most per ride as a number, or leave it blank.');
      return;
    }
    final s = _s.copyWith(
      timeZone: _zone.text.trim(),
      badgeText: _badge.text.trim(),
      addressHintText: _hint.text.trim(),
      maxTotal: () => cap,
    );
    final problem = s.problem;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    widget.onSave(s);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = widget.canEdit;
    final s = _s;
    return ListView(
      key: const ValueKey('place-fee-settings'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Text('Place fee settings', style: t.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('For the fees of every airport and place.', style: t.textTheme.bodySmall),
        const SizedBox(height: 8),
        AirportSwitch(
          title: 'Lock the fee of a ride booked for later',
          subtitle: 'Worked out for the pickup time when it is booked, so the rider pays what they saw',
          value: s.lockScheduled,
          onChanged: on ? (v) => setState(() => _s = s.copyWith(lockScheduled: v)) : null,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('place-fee-zone'),
                controller: _zone,
                enabled: on,
                decoration: const InputDecoration(
                  labelText: 'Time zone for days and hours',
                  helperText: 'An IANA time zone, e.g. Asia/Kuala_Lumpur',
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('place-fee-zone-pick'),
              tooltip: 'Choose a time zone',
              onPressed: on ? _pickZone : null,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('A percentage fee is of the fare.', style: t.textTheme.bodySmall),
        const Divider(height: 24),
        AirportSwitch(
          title: 'Label on the map',
          subtitle: 'The place and its fee on the pickup or drop-off pin',
          value: s.showMapLabel,
          onChanged: on ? (v) => setState(() => _s = s.copyWith(showMapLabel: v)) : null,
        ),
        AirportSwitch(
          title: 'Hint under the address',
          value: s.showAddressHint,
          onChanged: on ? (v) => setState(() => _s = s.copyWith(showAddressHint: v)) : null,
        ),
        TextField(
          key: const ValueKey('place-fee-hint-text'),
          controller: _hint,
          enabled: on,
          maxLength: 120,
          decoration: const InputDecoration(
            labelText: 'Address hint',
            helperText: '{name} is the fee or place, {amount} the fee',
          ),
        ),
        AirportSwitch(
          title: 'Badge on the vehicle cards',
          subtitle: 'The fare on the card includes the place fees',
          value: s.showCardBadge,
          onChanged: on ? (v) => setState(() => _s = s.copyWith(showCardBadge: v)) : null,
        ),
        TextField(
          key: const ValueKey('place-fee-badge-text'),
          controller: _badge,
          enabled: on,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Badge text'),
        ),
        TextField(
          key: const ValueKey('place-fee-cap'),
          controller: _cap,
          enabled: on,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(
            labelText: 'Most all place fees add to one ride (${widget.currency})',
            helperText: 'Blank for no most',
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, key: const ValueKey('place-fee-settings-error'), style: TextStyle(color: t.colorScheme.error)),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('place-fee-settings-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: on ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}
