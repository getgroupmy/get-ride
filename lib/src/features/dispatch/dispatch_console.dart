// The dispatch console (migration 0251): a new order for a walk-in customer,
// sent to a group or one driver, and the live board of the stand's orders.
// Stand staff see only the controls their access allows; the server checks
// every action again.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/dispatch.dart';
import '../../core/fare.dart';
import '../../data/app_display_repository.dart' show rideServicesProvider;
import '../../data/dispatch_repository.dart';
import '../../data/route_estimate_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../../widgets/date_boxes.dart';
import '../ride/map_place_picker.dart';
import '../ride/place_search.dart' show PlaceSearchMode, showPlaceSearch;
import 'dispatch_ticket.dart';

/// The board of one stand (null: every stand the caller may see), live.
final dispatchBoardProvider = StreamProvider.autoDispose.family<List<DispatchOrder>, String?>(
  (ref, standId) => ref.watch(dispatchRepositoryProvider).watchBoard(standId: standId),
);

/// The drivers near a stand, nearest first.
final dispatchDriversProvider = FutureProvider.autoDispose.family<List<NearbyDriver>, String>(
  (ref, standId) => ref.watch(dispatchRepositoryProvider).drivers(standId),
);

/// Today's figures for a stand (with See reports).
final dispatchReportProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, standId) => ref.watch(dispatchRepositoryProvider).report(standId),
);

/// A stand's GET.credit standing for counter-paid orders (the balance chip).
final standCreditProvider = FutureProvider.autoDispose.family<StandCredit, String>(
  (ref, standId) => ref.watch(dispatchRepositoryProvider).standCredit(standId),
);

/// The service names offered (the catalogue, else the built-in list).
final dispatchServiceNamesProvider = Provider.autoDispose<List<String>>((ref) {
  final list = ref.watch(rideServicesProvider).value ?? rideServices;
  return [for (final s in list) s.name];
});

/// The console: the form beside the board on a wide screen, above it on a
/// phone. [stands] are the stands the caller works at (admins: every one).
class DispatchConsole extends ConsumerStatefulWidget {
  const DispatchConsole({super.key, required this.stands, this.allStands = false, this.ticking = true});

  final List<DispatchStand> stands;

  /// The board holds every stand (an admin's console).
  final bool allStands;

  /// The waiting ages count up each second (off in tests).
  final bool ticking;

  @override
  ConsumerState<DispatchConsole> createState() => _DispatchConsoleState();
}

class _DispatchConsoleState extends ConsumerState<DispatchConsole> {
  late String _standId = widget.stands.first.id;

  DispatchStand get _stand => widget.stands.firstWhere((s) => s.id == _standId, orElse: () => widget.stands.first);

  @override
  Widget build(BuildContext context) {
    final stand = _stand;
    final form = NewOrderForm(
      key: ValueKey('new-order-${stand.id}'),
      stands: widget.stands,
      stand: stand,
      onStand: (id) => setState(() => _standId = id),
    );
    final board = OrderBoard(
      standId: widget.allStands ? null : stand.id,
      stands: widget.stands,
      showStand: widget.allStands,
      ticking: widget.ticking,
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 860) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 380, child: _Panel(child: form)),
                const SizedBox(width: 16),
                Expanded(child: _Panel(child: board)),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Panel(child: form),
            const SizedBox(height: 16),
            _Panel(child: board),
          ],
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerLow,
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    );
  }
}

// ---- The new order ------------------------------------------------------------------

class NewOrderForm extends ConsumerStatefulWidget {
  const NewOrderForm({super.key, required this.stands, required this.stand, required this.onStand});

  final List<DispatchStand> stands;
  final DispatchStand stand;
  final ValueChanged<String> onStand;

  @override
  ConsumerState<NewOrderForm> createState() => _NewOrderFormState();
}

class _NewOrderFormState extends ConsumerState<NewOrderForm> {
  final _dest = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pax = TextEditingController(text: '1');
  final _fare = TextEditingController();
  final _note = TextEditingController();
  LatLng? _destPoint;
  String? _destAddress;
  double? _km;
  int? _min;
  String? _service;
  FareMode _fareMode = FareMode.meter;
  // The Call centre's defaults: cash to the driver, nearby drivers, the app's fare.
  late CounterPayment _payment = widget.stand.isCallCentre ? CounterPayment.cash : CounterPayment.counter;
  late DispatchMode _mode = widget.stand.isCallCentre
      ? DispatchMode.nearby
      : sendModes(widget.stand.perms).firstOrNull ?? DispatchMode.broadcast;
  String? _groupId;
  String? _driverId;
  String? _error;
  bool _busy = false;

  // The Call centre: how they asked, where they are, and their account.
  BookedVia _via = BookedVia.phone;
  final _pickup = TextEditingController();
  String? _pickupAddress;
  LatLng? _pickupPoint;
  ({bool found, String? name})? _account;
  Timer? _lookup;

  // Booked ahead.
  bool _later = false;
  final _date = TextEditingController();
  final _time = TextEditingController();
  int _lead = 30;

  @override
  void initState() {
    super.initState();
    _groupId = widget.stand.groups.firstOrNull?.id;
    if (widget.stand.isCallCentre) _fareMode = FareMode.estimate;
    _phone.addListener(_phoneChanged);
  }

  @override
  void dispose() {
    _lookup?.cancel();
    for (final c in [_dest, _name, _phone, _pax, _fare, _note, _pickup, _date, _time]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The Call centre looks the number up as it is typed (a moment after).
  String _looked = '';
  void _phoneChanged() {
    if (!widget.stand.isCallCentre) return;
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits == _looked) return;
    _looked = digits;
    _lookup?.cancel();
    if (digits.length < 8) {
      if (_account != null) setState(() => _account = null);
      return;
    }
    _lookup = Timer(const Duration(milliseconds: 600), () async {
      try {
        final a = await ref.read(dispatchRepositoryProvider).lookupCustomer(_phone.text);
        if (mounted && _phone.text.replaceAll(RegExp(r'\D'), '') == digits) setState(() => _account = a);
      } catch (_) {}
    });
  }

  DateTime? get _pickupAt => _later ? parsePickupAt(_date.text, _time.text) : null;

  /// Where the trip starts: the stand, or the Call centre customer's address.
  LatLng? get _from => widget.stand.isCallCentre
      ? _pickupPoint
      : (widget.stand.lat == null ? null : LatLng(widget.stand.lat!, widget.stand.lng!));

  Future<void> _findPickup() async {
    final pick = await showPlaceSearch(
      context,
      title: 'Pickup',
      mode: PlaceSearchMode.address,
      fieldLabel: 'Pickup address',
      initialQuery: _pickup.text,
    );
    if (pick == null || !mounted) return;
    final place = pick.pickOnMap ? await pickPlaceOnMap(context, start: _pickupPoint) : pick.place;
    if (place == null || !mounted) return;
    setState(() {
      _pickup.text = place.name;
      _pickupAddress = place.address;
      _pickupPoint = place.point;
    });
    await _estimateRoute();
  }

  NewOrder get _order => NewOrder(
    standId: widget.stand.id,
    dropName: _dest.text,
    dropAddress: _destAddress,
    dropLat: _destPoint?.latitude,
    dropLng: _destPoint?.longitude,
    distanceKm: _km,
    durationMin: _min,
    customerName: _name.text,
    customerPhone: _phone.text,
    service: _service,
    passengers: int.tryParse(_pax.text.trim()) ?? 0,
    fareMode: _fareMode,
    fare: double.tryParse(_fare.text.trim()),
    payment: _payment,
    note: _note.text,
    mode: _mode,
    groupId: _groupId,
    driverId: _driverId,
    bookedVia: widget.stand.isCallCentre ? _via : null,
    pickupName: widget.stand.isCallCentre ? _pickup.text : null,
    pickupAddress: widget.stand.isCallCentre ? _pickupAddress : null,
    pickupLat: widget.stand.isCallCentre ? _pickupPoint?.latitude : null,
    pickupLng: widget.stand.isCallCentre ? _pickupPoint?.longitude : null,
    pickupAt: _pickupAt,
    leadMinutes: _lead,
  );

  Future<void> _pickOnMap() async {
    final pick = await showPlaceSearch(
      context,
      title: 'Destination',
      near: _from,
      mode: PlaceSearchMode.address,
      fieldLabel: 'Destination',
      initialQuery: _dest.text,
    );
    if (pick == null || !mounted) return;
    final place = pick.pickOnMap ? await pickPlaceOnMap(context, start: _destPoint ?? _from) : pick.place;
    if (place == null || !mounted) return;
    setState(() {
      _dest.text = place.name;
      _destAddress = place.address;
      _destPoint = place.point;
    });
    await _estimateRoute();
  }

  Future<void> _estimateRoute() async {
    final from = _from, to = _destPoint;
    if (from == null || to == null) return;
    try {
      final e = await ref.read(routeEstimateRepositoryProvider).estimate(from, to);
      if (e == null || !mounted) return;
      setState(() {
        _km = e.distanceKm;
        _min = e.durationMin.round();
        if (_fareMode == FareMode.estimate) _fare.text = _estimate().toStringAsFixed(2);
      });
    } catch (_) {}
  }

  /// The app's fare for the trip, worked out like a normal booking.
  double _estimate() {
    final list = ref.read(rideServicesProvider).value ?? rideServices;
    final svc = list.where((s) => s.name == _service).firstOrNull;
    return calculateFare(_km ?? 0, (_min ?? 0).toDouble(), multiplier: svc?.multiplier ?? 1);
  }

  Future<void> _send() async {
    if (_later && _pickupAt == null) {
      setState(() => _error = 'Enter the pickup date and time.');
      return;
    }
    final o = _order;
    final problem = o.problemFor(widget.stand);
    setState(() => _error = problem);
    if (problem != null) return;
    setState(() => _busy = true);
    try {
      final made = await ref.read(dispatchRepositoryProvider).create(o);
      if (!mounted) return;
      setState(() {
        for (final c in [_dest, _name, _phone, _fare, _note, _pickup, _date, _time]) {
          c.clear();
        }
        _pickupPoint = null;
        _pickupAddress = null;
        _account = null;
        _later = false;
        _pax.text = '1';
        _destPoint = null;
        _destAddress = null;
        _km = null;
        _min = null;
        _driverId = null;
      });
      ref.invalidate(dispatchBoardProvider);
      ref.invalidate(standCreditProvider(widget.stand.id));
      await showDispatchTicket(context, made);
    } catch (e) {
      if (mounted) setState(() => _error = dispatchErrorText(e));
      if ('$e'.contains('STAND_CREDIT_LIMIT')) ref.invalidate(standCreditProvider(widget.stand.id));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stand = widget.stand;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final services = ref.watch(dispatchServiceNamesProvider);
    final modes = sendModes(stand.perms);
    // "Nearby drivers" sits with the groups (the Call centre's), so it counts as broadcasting here.
    final shown = _mode == DispatchMode.nearby ? DispatchMode.broadcast : _mode;
    if (!modes.contains(shown) && modes.isNotEmpty) _mode = modes.first;
    final fares = fareModes(stand);
    if (!fares.contains(_fareMode)) _fareMode = FareMode.meter;
    final group = stand.groups.where((g) => g.id == _groupId).firstOrNull;
    final credit = stand.isCallCentre ? null : ref.watch(standCreditProvider(stand.id)).value;
    final counterBlocked = credit != null && credit.applies && credit.blocked;
    if (counterBlocked && _payment.atCounter) _payment = CounterPayment.cash;

    Widget label(String s) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(s, style: muted),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('New order', style: t.textTheme.titleMedium),
        if (widget.stands.length > 1) ...[
          label('Pickup'),
          SearchableDropdownFormField<String>(
            key: const ValueKey('order-stand'),
            initialValue: stand.id,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            items: [
              for (final s in widget.stands)
                DropdownMenuItem(
                  value: s.id,
                  child: Text(s.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => v == null ? null : widget.onStand(v),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Pickup: ${stand.name}', style: muted),
          ),
        if (stand.isCallCentre) ...[
          label('Booked by'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final v in BookedVia.values)
                ChoiceChip(
                  key: ValueKey('via-${v.name}'),
                  label: Text(v.label),
                  selected: _via == v,
                  onSelected: (_) => setState(() => _via = v),
                ),
            ],
          ),
          label('Pickup address'),
          TextField(
            key: const ValueKey('order-pickup'),
            controller: _pickup,
            readOnly: true,
            onTap: _findPickup,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              hintText: 'Search the address, or drop a pin',
              suffixIcon: IconButton(
                tooltip: 'Find the pickup',
                icon: const Icon(Icons.search),
                onPressed: _findPickup,
              ),
            ),
          ),
          if (_pickupAddress != null && _pickupAddress != _pickup.text) Text(_pickupAddress!, style: muted),
        ],
        label('When'),
        SegmentedButton<bool>(
          key: const ValueKey('order-when'),
          segments: const [
            ButtonSegment(value: false, label: Text('Now')),
            ButtonSegment(value: true, label: Text('Schedule')),
          ],
          selected: {_later},
          onSelectionChanged: (v) => setState(() => _later = v.first),
        ),
        if (_later) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: DateBoxesField(
                  key: const ValueKey('order-date'),
                  label: 'Pickup date',
                  controller: _date,
                  firstDate: DateUtils.dateOnly(DateTime.now()),
                  lastDate: DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 30)),
                  isRequired: true,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const ValueKey('order-time'),
                  controller: _time,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Time',
                    hintText: '14:30',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Send to drivers', style: muted),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final m in dispatchLeadMinutes)
                ChoiceChip(
                  key: ValueKey('lead-$m'),
                  label: Text('$m min before'),
                  selected: _lead == m,
                  onSelected: (_) => setState(() => _lead = m),
                ),
            ],
          ),
          Text(
            'Like scheduled rides in the app: an assigned driver is asked to confirm now and reminded before '
            'pickup; a broadcast goes out at the time chosen above.',
            style: muted,
          ),
        ],
        label('Destination'),
        TextField(
          key: const ValueKey('order-dest'),
          controller: _dest,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            hintText: 'Where to?',
            suffixIcon: IconButton(
              tooltip: 'Pick on the map',
              icon: const Icon(Icons.map_outlined),
              onPressed: _pickOnMap,
            ),
          ),
        ),
        if (_km != null) Text('${_km!.toStringAsFixed(1)} km · ${_min ?? 0} min', style: muted),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  label(stand.isCallCentre ? 'Customer name' : 'Customer name (optional)'),
                  TextField(
                    key: const ValueKey('order-name'),
                    controller: _name,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  label(stand.isCallCentre ? 'Phone' : 'Phone (optional)'),
                  TextField(
                    key: const ValueKey('order-phone'),
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (stand.isCallCentre && _account != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _account!.found
                  ? 'Found a GET.ride account: ${_account!.name ?? 'customer'}. The ride is booked on their account, so it '
                        'shows in their app with live tracking.'
                  : "No GET.ride account for this number. The ride is booked as a guest; they get the driver's details "
                        'and a tracking link by SMS.',
              key: const ValueKey('order-account'),
              style: muted,
            ),
          ),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  label('Service'),
                  SearchableDropdownFormField<String>(
                    key: const ValueKey('order-service'),
                    initialValue: _service,
                    isExpanded: true,
                    hint: const Text('Any'),
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                    items: [for (final s in services) DropdownMenuItem(value: s, child: Text(s))],
                    onChanged: (v) => setState(() => _service = v),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  label('Passengers'),
                  TextField(
                    key: const ValueKey('order-pax'),
                    controller: _pax,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  ),
                ],
              ),
            ),
          ],
        ),
        label('Fare'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in fares)
              ChoiceChip(
                key: ValueKey('fare-${m.name}'),
                label: Text(m.label),
                selected: _fareMode == m,
                onSelected: (_) => setState(() {
                  _fareMode = m;
                  if (m == FareMode.estimate && _fare.text.isEmpty && _km != null) {
                    _fare.text = _estimate().toStringAsFixed(2);
                  }
                }),
              ),
          ],
        ),
        if (_fareMode != FareMode.meter) ...[
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('order-fare'),
            controller: _fare,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              prefixText: 'RM ',
              labelText: _fareMode == FareMode.fixed ? 'Fixed fare' : 'App fare',
              helperText: _fareMode == FareMode.estimate
                  ? 'Worked out like a normal booking; pick the place on the map.'
                  : null,
            ),
          ),
        ],
        if (stand.fee.type != FeeType.none && stand.fee.value > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Stand fee: ${stand.fee.label}', style: muted),
          ),
        label('Payment'),
        if (credit != null && credit.applies)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                key: const ValueKey('stand-credit'),
                avatar: Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 18,
                  color: counterBlocked ? t.colorScheme.error : t.colorScheme.onSurfaceVariant,
                ),
                label: Text(credit.label),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        if (counterBlocked)
          Container(
            key: const ValueKey('stand-credit-banner'),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: t.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: t.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$standCreditTopUpText. Cash to driver orders still go out.',
                    style: TextStyle(color: t.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in CounterPayment.values)
              if (!(stand.isCallCentre && p == CounterPayment.counter))
                if (counterBlocked && p.atCounter)
                  Tooltip(
                    message: standCreditTopUpText,
                    child: ChoiceChip(key: ValueKey('pay-${p.name}'), label: Text(p.label), selected: false),
                  )
                else
                  ChoiceChip(
                    key: ValueKey('pay-${p.name}'),
                    label: Text(p.label),
                    selected: _payment == p,
                    onSelected: (_) => setState(() => _payment = p),
                  ),
          ],
        ),
        label('Note for the driver'),
        TextField(
          key: const ValueKey('order-note'),
          controller: _note,
          maxLines: 2,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        ),
        const SizedBox(height: 12),
        if (modes.length == 2)
          SegmentedButton<DispatchMode>(
            key: const ValueKey('order-mode'),
            segments: const [
              ButtonSegment(value: DispatchMode.broadcast, label: Text('Broadcast')),
              ButtonSegment(value: DispatchMode.assign, label: Text('Assign a driver')),
            ],
            selected: {_mode == DispatchMode.nearby ? DispatchMode.broadcast : _mode},
            onSelectionChanged: (s) => setState(() {
              _mode = s.first == DispatchMode.broadcast && stand.isCallCentre ? DispatchMode.nearby : s.first;
            }),
          )
        else if (modes.length == 1)
          Text(
            'Your access: ${modes.first == DispatchMode.assign ? 'assign a driver' : 'broadcast'} only',
            style: muted,
          )
        else
          Text("Your access doesn't include sending orders. Ask your stand admin.", style: muted),
        const SizedBox(height: 8),
        if (modes.contains(DispatchMode.broadcast) && _mode != DispatchMode.assign)
          _GroupPicker(
            groups: stand.groups,
            selected: _mode == DispatchMode.nearby ? null : _groupId,
            onSelected: (id) => setState(() {
              _mode = DispatchMode.broadcast;
              _groupId = id;
            }),
            describe: _mode == DispatchMode.nearby ? null : group,
            nearby: stand.isCallCentre,
            nearbySelected: _mode == DispatchMode.nearby,
            onNearby: () => setState(() => _mode = DispatchMode.nearby),
          )
        else if (modes.contains(_mode))
          _DriverPicker(
            standId: stand.id,
            service: _service,
            selected: _driverId,
            onSelected: (id) => setState(() => _driverId = id),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              key: const ValueKey('order-error'),
              style: TextStyle(color: t.colorScheme.error),
            ),
          ),
        const SizedBox(height: 10),
        FilledButton(
          key: const ValueKey('order-send'),
          onPressed: _busy || modes.isEmpty ? null : _send,
          child: Text(_mode == DispatchMode.assign ? 'Assign order' : 'Broadcast order'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('A ticket is shown (and sent by SMS when there is a phone) for the customer.', style: muted),
        ),
      ],
    );
  }
}

class _GroupPicker extends StatelessWidget {
  const _GroupPicker({
    required this.groups,
    required this.selected,
    required this.onSelected,
    this.describe,
    this.nearby = false,
    this.nearbySelected = false,
    this.onNearby,
  });

  /// The Call centre's "Nearby drivers · normal booking" choice.
  final bool nearby;
  final bool nearbySelected;
  final VoidCallback? onNearby;
  final List<DispatchGroup> groups;
  final String? selected;
  final ValueChanged<String> onSelected;
  final DispatchGroup? describe;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    if (groups.isEmpty && !nearby) return Text('This stand has no groups yet.', style: muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Send to', style: muted),
        const SizedBox(height: 4),
        ListSearchFilter(
          count: groups.length,
          hint: 'Search groups',
          fieldKey: const ValueKey('group-search'),
          builder: (_, q) => Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (nearby)
                ChoiceChip(
                  key: const ValueKey('group-nearby'),
                  label: const Text('Nearby drivers · normal booking'),
                  selected: nearbySelected,
                  onSelected: (_) => onNearby?.call(),
                ),
              for (final g in groups)
                if (q.isEmpty || g.name.toLowerCase().contains(q.toLowerCase()))
                  ChoiceChip(
                    key: ValueKey('group-${g.id}'),
                    label: Text('${g.name} · ${g.kind.label}'),
                    selected: selected == g.id,
                    onSelected: (_) => onSelected(g.id),
                  ),
            ],
          ),
        ),
        if (nearbySelected)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Goes to nearby drivers exactly like a booking made in the app (same fare, same dispatch rules).',
              style: muted,
            ),
          ),
        if (describe != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${describe!.howItWorks} ${describe!.members} driver${describe!.members == 1 ? '' : 's'} in it.',
              style: muted,
            ),
          ),
      ],
    );
  }
}

class _DriverPicker extends ConsumerWidget {
  const _DriverPicker({required this.standId, required this.selected, required this.onSelected, this.service});

  final String standId;
  final String? service;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final async = ref.watch(dispatchDriversProvider(standId));
    final drivers = sortNearest(async.value ?? const [], service: service);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text('Driver (nearest first)', style: muted)),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => ref.invalidate(dispatchDriversProvider(standId)),
            ),
          ],
        ),
        if (async.isLoading && async.value == null) const LinearProgressIndicator(),
        if (async.hasError) Text('Could not load drivers.', style: TextStyle(color: t.colorScheme.error)),
        if (async.hasValue && drivers.isEmpty) Text('No driver is online nearby.', style: muted),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: ListSearchFilter(
              count: drivers.length,
              hint: 'Search drivers',
              fieldKey: const ValueKey('driver-search'),
              builder: (_, q) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final d in drivers)
                    if (q.isEmpty || '${d.name} ${d.carLine ?? ''}'.toLowerCase().contains(q.toLowerCase()))
                      _DriverRow(driver: d, selected: selected == d.id, onTap: () => onSelected(d.id)),
                ],
              ),
            ),
          ),
        ),
        Text(
          "The driver gets the order straight away and must accept it. If they decline or don't answer in "
          '${assignWindow.inSeconds} s, it comes back to you.',
          style: muted,
        ),
      ],
    );
  }
}

class _DriverRow extends StatelessWidget {
  const _DriverRow({required this.driver, required this.selected, required this.onTap});
  final NearbyDriver driver;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dot = switch (driver.state) {
      DriverState.atStand => t.colorScheme.primary,
      DriverState.free => Colors.green,
      DriverState.onTrip => t.colorScheme.error,
      DriverState.offline => t.colorScheme.outline,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? t.colorScheme.primaryContainer : t.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? t.colorScheme.primary : t.colorScheme.outlineVariant),
        ),
        child: InkWell(
          key: ValueKey('driver-${driver.id}'),
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(driver.name, overflow: TextOverflow.ellipsis),
                      if (driver.carLine != null)
                        Text(
                          driver.carLine!,
                          key: ValueKey('driver-car-${driver.id}'),
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodySmall,
                        ),
                      Text(
                        driver.subtitle,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (selected) Icon(Icons.check_circle, color: t.colorScheme.primary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The server's refusals in words.
String dispatchErrorText(Object e) {
  final s = '$e';
  final hint = RegExp(r'hint: ([^,)]+)').firstMatch(s)?.group(1);
  if (s.contains('not_authorized') || s.contains('NO_PERMISSION')) return hint ?? "You can't do that here.";
  if (s.contains('STAND_CREDIT_LIMIT')) return hint ?? '$standCreditTopUpText. Cash to driver still works.';
  if (s.contains('WRONG_STATUS')) return hint ?? 'The order has moved on; the board shows it as it is now.';
  if (s.contains('DISPATCH_')) return hint ?? 'Check the order and try again.';
  return "Couldn't reach the server. Try again.";
}

// ---- The board ---------------------------------------------------------------------------

class OrderBoard extends ConsumerStatefulWidget {
  const OrderBoard({
    super.key,
    required this.standId,
    required this.stands,
    this.showStand = false,
    this.ticking = true,
  });

  final String? standId;
  final List<DispatchStand> stands;
  final bool showStand;
  final bool ticking;

  @override
  ConsumerState<OrderBoard> createState() => _OrderBoardState();
}

class _OrderBoardState extends ConsumerState<OrderBoard> {
  Timer? _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    if (widget.ticking) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  StandPerms _permsFor(String standId) =>
      widget.stands.where((s) => s.id == standId).firstOrNull?.perms ?? const StandPerms();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final async = ref.watch(dispatchBoardProvider(widget.standId));
    final orders = async.value ?? const <DispatchOrder>[];
    final cols = boardColumns(orders);
    final stand = widget.stands.where((s) => s.id == widget.standId).firstOrNull;
    final reports = stand?.perms.reports ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.standId == null ? 'Orders · all stands' : 'Orders at ${stand?.shortName ?? 'this stand'}',
          style: t.textTheme.titleMedium,
        ),
        if (reports && widget.standId != null) _ReportLine(standId: widget.standId!),
        const SizedBox(height: 8),
        if (async.hasError && async.value == null)
          Text(
            'Could not load the orders. ${dispatchErrorText(async.error!)}',
            style: TextStyle(color: t.colorScheme.error),
          ),
        if (async.isLoading && async.value == null) const LinearProgressIndicator(),
        LayoutBuilder(
          builder: (context, c) {
            final per = c.maxWidth >= 1200 ? 5 : (c.maxWidth >= 1000 ? 4 : (c.maxWidth >= 520 ? 2 : 1));
            final width = (c.maxWidth - 10 * (per - 1)) / per;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final col in BoardColumn.values)
                  SizedBox(
                    width: width,
                    child: _BoardColumnView(
                      column: col,
                      orders: cols[col]!,
                      now: _now,
                      perms: _permsFor,
                      showStand: widget.showStand,
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Waiting orders show who they went to and for how long. Re-send widens a broadcast or picks another '
          "driver. Every action is logged with the person's name.",
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ReportLine extends ConsumerWidget {
  const _ReportLine({required this.standId});
  final String standId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(dispatchReportProvider(standId)).value;
    if (r == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    num n(String k) => (r[k] as num?) ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Today: ${n('orders')} orders · ${n('done')} done · ${n('cancelled')} cancelled · '
        'fares RM ${n('fares').toStringAsFixed(2)} · stand fees RM ${n('fees').toStringAsFixed(2)}',
        key: const ValueKey('dispatch-report'),
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _BoardColumnView extends StatelessWidget {
  const _BoardColumnView({
    required this.column,
    required this.orders,
    required this.now,
    required this.perms,
    required this.showStand,
  });

  final BoardColumn column;
  final List<DispatchOrder> orders;
  final DateTime now;
  final StandPerms Function(String standId) perms;
  final bool showStand;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Column(
      key: ValueKey('board-${column.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(column.label, style: muted)),
            Text('${orders.length}', style: muted),
          ],
        ),
        const SizedBox(height: 6),
        if (orders.isEmpty) Text('None', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        for (final o in orders)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OrderCard(order: o, now: now, perms: perms(o.standId), showStand: showStand),
          ),
      ],
    );
  }
}

class OrderCard extends ConsumerWidget {
  const OrderCard({super.key, required this.order, required this.now, required this.perms, this.showStand = false});

  final DispatchOrder order;
  final DateTime now;
  final StandPerms perms;
  final bool showStand;

  Future<void> _act(BuildContext context, WidgetRef ref, String action, [Map<String, dynamic> args = const {}]) async {
    try {
      await ref.read(dispatchRepositoryProvider).act(order.id, action, args);
      ref.invalidate(dispatchBoardProvider);
    } catch (e) {
      if (context.mounted) showError(context, dispatchErrorText(e));
    }
  }

  Future<void> _resend(BuildContext context, WidgetRef ref, {required bool reassign}) async {
    final choice = await showAppSheet<_Resend>(
      id: 'dispatch.resend',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ResendSheet(order: order, perms: perms, reassign: reassign),
    );
    if (choice == null || !context.mounted) return;
    final action = reassign
        ? 'reassign'
        : (choice.widen ? 'widen' : (choice.driverId != null ? 'resend_driver' : 'resend_group'));
    await _act(context, ref, action, {'driver_id': ?choice.driverId, 'group_id': ?choice.groupId});
  }

  Future<void> _complete(BuildContext context, WidgetRef ref) async {
    if (order.fareMode == FareMode.meter && order.fare == null) {
      final fare = await showAppDialog<double>(
        id: 'dispatch.meter-fare',
        context: context,
        builder: (_) => const MeterFareDialog(),
      );
      if (fare == null || !context.mounted) return;
      await _act(context, ref, 'complete', {'fare': fare});
      return;
    }
    await _act(context, ref, 'complete');
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(
      id: 'dispatch.cancel',
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Cancel ${order.ticketNo}?'),
        content: Text(
          order.hasDriver
              ? '${order.driverName ?? 'The driver'} is told the order is cancelled.'
              : 'The drivers stop seeing it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel order')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (order.isScheduled) {
      await _scheduled(context, ref, 'cancel');
    } else {
      await _act(context, ref, 'cancel');
    }
  }

  Future<void> _scheduled(
    BuildContext context,
    WidgetRef ref,
    String action, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      await ref.read(dispatchRepositoryProvider).scheduledAction(order.id, action, args);
      ref.invalidate(dispatchBoardProvider);
    } catch (e) {
      if (context.mounted) showError(context, dispatchErrorText(e));
    }
  }

  Future<void> _editTime(BuildContext context, WidgetRef ref) async {
    final r = await showAppDialog<PickupTimeChange>(
      id: 'dispatch.edit-time',
      context: context,
      builder: (_) => EditPickupTimeDialog(at: order.pickupAt?.toLocal(), lead: order.leadMinutes),
    );
    if (r == null || !context.mounted) return;
    await _scheduled(context, ref, 'reschedule', {'pickup_at': r.at.toUtc().toIso8601String(), 'lead_minutes': r.lead});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final a = orderActions(order, perms);
    final pillColor = switch (order.status) {
      _ when order.isScheduled => t.colorScheme.primary,
      'open' => order.returned(now) ? t.colorScheme.error : t.colorScheme.tertiary,
      'accepted' || 'arrived' => t.colorScheme.primary,
      'on_trip' => t.colorScheme.secondary,
      'completed' => Colors.green.shade700,
      _ => t.colorScheme.error,
    };
    final pillInk = t.brightness == Brightness.dark ? Color.lerp(pillColor, Colors.white, 0.45)! : pillColor;
    return Container(
      key: ValueKey('order-${order.id}'),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(order.ticketNo, style: t.textTheme.labelLarge?.copyWith(fontFamily: 'monospace')),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: t.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(order.pill(now), style: t.textTheme.labelSmall?.copyWith(color: pillInk)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            order.routeLine,
            key: ValueKey('order-route-${order.id}'),
            style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (order.bookedVia != null)
            Text(
              'Booked by ${order.bookedVia!.inLine}${order.riderAccount ? ' · on their account' : ''}',
              key: ValueKey('order-via-${order.id}'),
              style: muted,
            ),
          Text([?order.service, order.fareText, order.payment.label].join(' · '), style: muted),
          if (order.isScheduled) ...[
            Text(order.scheduleState, key: ValueKey('order-schedule-${order.id}'), style: muted),
            if (order.driverConfirmed)
              for (final (i, line) in order.driverLines.indexed)
                Text(line, key: ValueKey('order-driver-$i-${order.id}'), style: muted)
            else
              Text('To: ${order.sentTo(now)}', style: muted),
          ] else if (order.hasDriver || order.status == 'completed')
            for (final (i, line) in order.driverLines.indexed)
              Text(line, key: ValueKey('order-driver-$i-${order.id}'), style: muted)
          else
            Text('To: ${order.sentTo(now)}', style: muted),
          if (showStand) Text(order.standName, style: muted),
          if (order.createdByName != null) Text('By ${order.createdByName}', style: muted),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              if (a.sendNow)
                _SmallButton(
                  key: ValueKey('send-now-${order.id}'),
                  label: 'Send now',
                  onPressed: () => _scheduled(context, ref, 'release'),
                ),
              if (a.editTime)
                _SmallButton(
                  key: ValueKey('edit-time-${order.id}'),
                  label: 'Edit time',
                  onPressed: () => _editTime(context, ref),
                ),
              if (a.resend)
                _SmallButton(
                  key: ValueKey('resend-${order.id}'),
                  label: 'Re-send',
                  onPressed: () => _resend(context, ref, reassign: false),
                ),
              if (a.pickedUp)
                _SmallButton(
                  key: ValueKey('picked-${order.id}'),
                  label: 'Picked up',
                  onPressed: () => _act(context, ref, 'picked_up'),
                ),
              if (a.reassign)
                _SmallButton(
                  key: ValueKey('reassign-${order.id}'),
                  label: 'Reassign',
                  onPressed: () => _resend(context, ref, reassign: true),
                ),
              if (a.complete)
                _SmallButton(
                  key: ValueKey('complete-${order.id}'),
                  label: 'Complete',
                  onPressed: () => _complete(context, ref),
                ),
              if (a.cancel)
                _SmallButton(
                  key: ValueKey('cancel-${order.id}'),
                  label: 'Cancel',
                  onPressed: () => _cancel(context, ref),
                ),
              _SmallButton(
                key: ValueKey('ticket-${order.id}'),
                label: 'Ticket',
                onPressed: () => showDispatchTicket(context, order),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 34),
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}

class _Resend {
  const _Resend({this.widen = false, this.groupId, this.driverId});
  final bool widen;
  final String? groupId;
  final String? driverId;
}

class _ResendSheet extends ConsumerWidget {
  const _ResendSheet({required this.order, required this.perms, required this.reassign});

  final DispatchOrder order;
  final StandPerms perms;
  final bool reassign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final roles = ref.watch(dispatchRolesProvider).value;
    final stand = roles?.stands.where((s) => s.id == order.standId).firstOrNull;
    final groups = stand?.groups ?? const <DispatchGroup>[];
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          Text(reassign ? 'Reassign ${order.ticketNo}' : 'Re-send ${order.ticketNo}', style: t.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!reassign && perms.broadcast)
            ListTile(
              key: const ValueKey('resend-widen'),
              leading: const Icon(Icons.wifi_tethering),
              title: const Text('Any nearby driver'),
              subtitle: const Text('Widen it beyond the group, like a normal booking'),
              onTap: () => Navigator.pop(context, const _Resend(widen: true)),
            ),
          if (perms.broadcast)
            for (final g in groups)
              ListTile(
                key: ValueKey('resend-group-${g.id}'),
                leading: const Icon(Icons.groups_outlined),
                title: Text(g.name),
                subtitle: Text(g.kind.label),
                onTap: () => Navigator.pop(context, _Resend(groupId: g.id)),
              ),
          if (perms.assign)
            ListTile(
              key: const ValueKey('resend-driver'),
              leading: const Icon(Icons.person_search_outlined),
              title: const Text('Pick a driver'),
              subtitle: const Text('Nearest first'),
              onTap: () async {
                final drivers = sortNearest(await ref.read(dispatchDriversProvider(order.standId).future));
                if (!context.mounted) return;
                final id = await showSearchPicker<String>(
                  context,
                  title: 'Pick a driver',
                  choices: [
                    for (final d in drivers)
                      (value: d.id, label: d.name, subtitle: [?d.carLine, d.subtitle].join('\n'), leading: null),
                  ],
                );
                if (id != null && context.mounted) Navigator.pop(context, _Resend(driverId: id));
              },
            ),
        ],
      ),
    );
  }
}

/// Asks what the meter shows, to complete a metered stand order.
class MeterFareDialog extends StatefulWidget {
  const MeterFareDialog({super.key});

  @override
  State<MeterFareDialog> createState() => MeterFareDialogState();
}

class MeterFareDialogState extends State<MeterFareDialog> {
  final _c = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Meter fare'),
    content: TextField(
      key: const ValueKey('meter-fare'),
      controller: _c,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(prefixText: 'RM ', errorText: _error, labelText: 'What the meter shows'),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
      FilledButton(
        onPressed: () {
          final v = double.tryParse(_c.text.trim());
          if (v == null || v <= 0) {
            setState(() => _error = 'Enter the fare');
            return;
          }
          Navigator.pop(context, v);
        },
        child: const Text('Complete'),
      ),
    ],
  );
}

/// A booking ahead's new pickup date and time, and how long before it goes out.
typedef PickupTimeChange = ({DateTime at, int lead});

class EditPickupTimeDialog extends StatefulWidget {
  const EditPickupTimeDialog({super.key, this.at, this.lead = 30});
  final DateTime? at;
  final int lead;

  @override
  State<EditPickupTimeDialog> createState() => _EditPickupTimeDialogState();
}

class _EditPickupTimeDialogState extends State<EditPickupTimeDialog> {
  late final _date = TextEditingController(
    text: widget.at == null
        ? ''
        : '${widget.at!.year}-${widget.at!.month.toString().padLeft(2, '0')}-${widget.at!.day.toString().padLeft(2, '0')}',
  );
  late final _time = TextEditingController(
    text: widget.at == null
        ? ''
        : '${widget.at!.hour.toString().padLeft(2, '0')}:${widget.at!.minute.toString().padLeft(2, '0')}',
  );
  late int _lead = widget.lead;
  String? _error;

  @override
  void dispose() {
    _date.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit pickup time'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DateBoxesField(
              label: 'Pickup date',
              controller: _date,
              firstDate: DateUtils.dateOnly(DateTime.now()),
              lastDate: DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 30)),
              isRequired: true,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('edit-time-field'),
              controller: _time,
              decoration: const InputDecoration(labelText: 'Time', hintText: '14:30', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final m in dispatchLeadMinutes)
                  ChoiceChip(
                    label: Text('$m min before'),
                    selected: _lead == m,
                    onSelected: (_) => setState(() => _lead = m),
                  ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
      FilledButton(
        key: const ValueKey('edit-time-save'),
        onPressed: () {
          final at = parsePickupAt(_date.text, _time.text);
          if (at == null || at.isBefore(DateTime.now().add(Duration(minutes: _lead + 5)))) {
            setState(() => _error = 'Pick a time at least ${_lead + 5} minutes from now.');
            return;
          }
          Navigator.pop(context, (at: at, lead: _lead));
        },
        child: const Text('Save'),
      ),
    ],
  );
}
