// The Courier page (home service box "Couriers", migration 0268): where to
// pick up and deliver, the recipient, the parcel size (S / M / L) and what
// is inside, the vehicle (only those that carry the size), the value and
// the prohibited items, who pays (the sender, or the recipient in cash on
// delivery) and the sender's price, then Find a courier. The request is a
// ride request of that vehicle's service, built on Freight's parts and bid
// on as any ride: couriers' offers come to My deliveries as the ride offer
// cards, and an accepted one opens the normal trip screens.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../config.dart';
import '../../core/book_for.dart' show DuplicateRideRequest;
import '../../core/commission.dart' show Geo;
import '../../core/courier.dart';
import '../../core/early_end.dart' show serviceTypeIds;
import '../../core/fare_tariff.dart';
import '../../core/format.dart';
import '../../core/freight.dart';
import '../../core/partner_type_rules.dart' show RegionScope;
import '../../core/payment_types.dart';
import '../../core/region_pricing.dart';
import '../../core/ride_option_places.dart';
import '../../core/ride_request_metadata.dart';
import '../../core/saved_drafts.dart';
import '../../data/app_display_repository.dart';
import '../../data/device_access.dart';
import '../../data/fare_tariff_repository.dart';
import '../../data/freight_repository.dart';
import '../../data/geo_service.dart' show Place;
import '../../data/models.dart';
import '../../data/ride_draft_store.dart';
import '../../data/ride_option_places_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/page_style_host.dart';
import '../../widgets/media_image.dart' show MediaIcon;
import '../../widgets/search_select.dart' show ListSearchFilter, searchSelectMatches;
import 'confirm_parts.dart' show paymentLook;
import 'delivery_look.dart';
import 'freight_parts.dart' show FreightVehicleImage;
import 'freight_screen.dart';

/// Opens the Courier page; with [resume], filled in as it was left
/// (Welcome back, saved_drafts.dart).
Future<void> openCourierPage(BuildContext context, {int tab = 0, Map<String, Object?>? resume}) => Navigator.of(context)
    .push<void>(AppPageRoute(id: 'ride.courier', builder: (_) => CourierScreen(initialTab: tab, resume: resume)));

/// A vehicle's own icon (Material Symbols'), by its name.
IconData courierVehicleIcon(FreightVehicle v) {
  final n = v.name.toLowerCase();
  if (n.contains('walk') || n.contains('foot')) return Icons.directions_walk;
  if (n.contains('bicycle') || n.contains('bike') && !n.contains('motor')) return Icons.pedal_bike;
  if (n.contains('motor')) return Icons.two_wheeler;
  return Icons.directions_car_outlined;
}

class CourierScreen extends ConsumerStatefulWidget {
  const CourierScreen({super.key, this.initialTab = 0, this.resume});

  /// 0: Send a parcel, 1: My deliveries.
  final int initialTab;

  /// A parcel left unfinished, to fill the form in with.
  final Map<String, Object?>? resume;

  @override
  ConsumerState<CourierScreen> createState() => _CourierScreenState();
}

class _CourierScreenState extends ConsumerState<CourierScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialTab);
  final _pickupDetails = TextEditingController();
  final _dropDetails = TextEditingController();
  final _note = TextEditingController();
  Place? _pickup, _drop;
  FreightRecipient? _recipient;
  ParcelSize _size = ParcelSize.s;
  List<String> _items = const [];
  String? _vehicleId;
  CourierPayer _payer = CourierPayer.sender;
  String _payment = 'Cash';
  double? _offer;
  double? _declared;
  bool _ack = false;
  FreightPickupContext? _context;
  LatLng? _contextAt;
  ({double km, double min})? _route;
  bool _booking = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
    try {
      _uid = ref.read(currentUserIdProvider);
    } catch (_) {}
    _saver = DraftSaver(SavedDraftKind.courier, ref.read(rideDraftStoreProvider), () => _uid);
    if (widget.resume case final r?) _restore(r);
    for (final c in [_pickupDetails, _dropDetails, _note]) {
      c.addListener(_typed);
    }
  }

  // ---- Welcome back (saved_drafts.dart) ----
  late final DraftSaver _saver;
  String? _uid;

  void _typed() => _saver.changed(_saved());

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _saver.changed(_saved());
  }

  /// The form as kept on the phone, once both ends are set. The
  /// confirmation about prohibited items is asked for again.
  Map<String, Object?>? _saved() {
    final a = _pickup, b = _drop;
    if (!draftPlaceReal(a) || !draftPlaceReal(b)) return null;
    return {
      'pickup': draftAddressToJson(a!, _pickupDetails.text),
      'drop': draftAddressToJson(b!, _dropDetails.text),
      if (_note.text.trim().isNotEmpty) 'note': _note.text,
      if (_recipient case final r?) 'recipient': {'name': r.name, 'phone': r.phone},
      'size': _size.name,
      if (_items.isNotEmpty) 'items': _items,
      'vehicle_id': ?_vehicleId,
      'vehicle_name': ?(_vehicleId == null ? null : _vehicle?.name),
      'payer': _payer.name,
      'payment': _payment,
      'offer': ?_offer,
      if (_offer != null) 'currency': _currency,
      'declared': ?_declared,
    };
  }

  void _restore(Map<String, Object?> m) {
    final a = draftAddressFromJson(m['pickup']), b = draftAddressFromJson(m['drop']);
    if (a != null) {
      _pickup = a.place;
      _pickupDetails.text = a.details;
    }
    if (b != null) {
      _drop = b.place;
      _dropDetails.text = b.details;
    }
    _note.text = draftText(m['note']) ?? '';
    final r = m['recipient'];
    if (r is Map && draftText(r['phone']) != null) _recipient = (name: '${r['name'] ?? ''}', phone: '${r['phone']}');
    _size = ParcelSize.values.where((x) => x.name == m['size']).firstOrNull ?? _size;
    final items = m['items'];
    if (items is List) _items = [for (final i in items) if (i is String && i.trim().isNotEmpty) i];
    _vehicleId = draftText(m['vehicle_id']);
    _payer = CourierPayer.values.where((x) => x.name == m['payer']).firstOrNull ?? _payer;
    _payment = draftText(m['payment']) ?? _payment;
    _offer = draftNumber(m['offer']);
    _declared = draftNumber(m['declared']);
  }

  @override
  void dispose() {
    _saver.dispose();
    _tabs.dispose();
    _pickupDetails.dispose();
    _dropDetails.dispose();
    _note.dispose();
    super.dispose();
  }

  CourierConfig get _config => ref.read(courierConfigProvider).value ?? const CourierConfig();

  /// The vehicles that carry the parcel size picked.
  List<FreightVehicle> get _vehicles =>
      courierVehiclesFor(ref.read(courierVehiclesProvider).value ?? const [], _size, _config);

  /// The vehicle chosen while it still carries the size, else the first.
  FreightVehicle? get _vehicle {
    final all = _vehicles;
    if (all.isEmpty) return null;
    return all.firstWhere((v) => v.id == _vehicleId, orElse: () => all.first);
  }

  FareTariff? _tariffFor(FreightVehicle v) {
    final a = _context?.area;
    return resolveFareTariff(
      ref.read(fareTariffsProvider).value ?? const [],
      Geo(country: a?.country, state: a?.state, city: a?.city, suburb: a?.suburb),
      vehicleService: v.id,
      serviceTypes: serviceTypeIds(v.service, ref.read(serviceBoxNamesProvider).value ?? const {}),
    );
  }

  String get _currency {
    final v = _vehicle;
    return (v == null ? null : _tariffFor(v)?.currency) ?? AppConfig.currency;
  }

  RegionPricing get _pricing => _context?.pricing ?? RegionPricing.none;

  FreightPlaceValues get _placeValues => freightPlaceValues(
    ref.read(rideOptionPlacesProvider).value ?? OptionPlaces.none,
    _context?.place ?? RegionScope.all,
    kind: DeliveryKind.courier,
  );

  String _money(double v) => formatMoney(v, _currency, v == v.roundToDouble() ? 0 : _pricing.fareDecimals);

  /// The estimate for this trip on [v]; null until both ends are set.
  double? _recommendedFor(FreightVehicle? v) {
    final r = _route;
    if (r == null || v == null) return null;
    return _pricing.roundFare(
      quoteFare(_tariffFor(v), r.km, r.min, multiplier: v.multiplier, fallbackCurrency: AppConfig.currency).fare,
    );
  }

  Future<void> _ends() async {
    final a = _pickup, b = _drop;
    final seq = ++_seq;
    if (a != null && _contextAt != a.point) {
      final c = await ref.read(freightPickupContextProvider)(a.point);
      if (!mounted || seq != _seq) return;
      setState(() {
        _context = c;
        _contextAt = a.point;
      });
    }
    if (a == null || b == null) {
      setState(() => _route = null);
      return;
    }
    final r = await ref.read(freightRouteProvider)(a.point, b.point);
    if (!mounted || seq != _seq) return;
    setState(() => _route = r);
  }

  Future<void> _place({required bool pickup}) async {
    final p = await ref.read(freightPlaceSearchProvider)(
      context,
      title: pickup ? 'Where to pick up' : 'Where to deliver',
      near: (pickup ? _pickup : _drop)?.point ?? _pickup?.point,
    );
    if (p == null || !mounted) return;
    setState(() => pickup ? _pickup = p : _drop = p);
    unawaited(_ends());
  }

  Future<void> _chooseRecipient() async {
    final r = await showAppSheet<FreightRecipient>(id: 'ride.courier-recipient',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FreightRecipientSheet(
        initial: _recipient,
        phoneRequired: true,
        note: _config.messageChannels.isEmpty
            ? 'The courier calls this number at drop-off.'
            : "We'll send them the tracking link and the confirmation code when the courier picks up.",
      ),
    );
    if (r != null && mounted) setState(() => _recipient = r.phone.trim().isEmpty ? null : r);
  }

  Future<void> _offerPrice() async {
    final style = currencyStyles[_currency.trim().toUpperCase()];
    final rec = _recommendedFor(_vehicle);
    final v = await showAppSheet<double>(id: 'ride.courier-offer',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FreightOfferSheet(
        title: 'Offer your price',
        note: null,
        initial: _offer ?? rec?.roundToDouble(),
        recommended: rec,
        currencyLabel: (style?.symbol ?? _currency).trim(),
        money: _money,
      ),
    );
    if (v != null && mounted) setState(() => _offer = v);
  }

  Future<void> _declare() async {
    final style = currencyStyles[_currency.trim().toUpperCase()];
    final cap = _placeValues.declaredCap;
    final v = await showAppSheet<double>(id: 'ride.courier-declared',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FreightAmountSheet(
        title: 'Value of your items',
        initial: _declared,
        currencyLabel: (style?.symbol ?? _currency).trim(),
        hint: 'Up to ${_money(cap)}. Items worth more need another way to send.',
        problem: (v) => declaredValueProblem(v, cap, _money),
      ),
    );
    if (v != null && mounted) setState(() => _declared = v);
  }

  Future<void> _showProhibited() => showAppSheet<void>(id: 'ride.courier-prohibited',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FreightProhibitedSheet(items: _config.prohibitedItems),
  );

  /// What the form has filled in, as the button and [_create] check it.
  CourierDraft get _draft => CourierDraft(
    pickup: _pickup != null,
    drop: _drop != null,
    size: _size,
    vehicle: _vehicle,
    recipientPhone: _recipient?.phone ?? '',
    declaredValue: _declared,
    declaredCap: _placeValues.declaredCap,
    prohibitedAck: _ack,
    offer: _offer,
  );

  Future<void> _create() async {
    final a = _pickup, b = _drop, v = _vehicle;
    final problem = courierDraftProblem(_draft, _config);
    if (problem != null) return showInfo(context, problem);
    setState(() => _booking = true);
    try {
      try {
        if (await ref.read(deviceBlockedProvider.future).timeout(const Duration(seconds: 5))) {
          if (mounted) showInfo(context, 'This device is not permitted to place a request.');
          return;
        }
      } catch (_) {}
      final ctx = _context ?? await ref.read(freightPickupContextProvider)(a!.point);
      if (!mounted) return;
      if (_context == null) setState(() => _context = ctx);
      Profile? profile;
      try {
        profile = await ref.read(profileProvider.future);
      } catch (_) {}
      final route = _route;
      final items = courierItemText(_items, _note.text);
      final payments = ref.read(paymentChoicesProvider).value ?? builtInPayments;
      // The recipient pays in cash; the sender any way offered.
      final payment = _payer == CourierPayer.recipient
          ? (payments.where((p) => p.kind == PaymentKind.cash).firstOrNull?.value ?? 'Cash')
          : resolvePayment(_payment, payments);
      String details(TextEditingController c, String label) => c.text.trim().isEmpty ? '' : '$label: ${c.text.trim()}';
      final note = [
        courierNote(items: items, size: _size, payer: _payer),
        details(_pickupDetails, 'Pickup'),
        details(_dropDetails, 'Drop-off'),
      ].where((x) => x.isNotEmpty).join(' · ');
      await ref.read(rideRepositoryProvider).createRequest(
        service: v!.name,
        pickupName: a!.name,
        pickupAddress: a.address,
        pickupLat: a.point.latitude,
        pickupLng: a.point.longitude,
        dropName: b!.name,
        dropAddress: b.address,
        dropLat: b.point.latitude,
        dropLng: b.point.longitude,
        distanceKm: route?.km ?? const Distance().as(LengthUnit.Meter, a.point, b.point) / 1000,
        durationMin: (route?.min ?? 0).round(),
        fare: _offer!,
        paymentMode: payment,
        note: note,
        riderName: profile?.name,
        riderPhone: profile?.phone,
        deviceOs: kIsWeb ? 'web' : defaultTargetPlatform.name,
        // Courier is bid on: the sender offers, couriers counter.
        offerMe: true,
        metadata: rideRequestMetadata(area: ctx.area, gender: profile?.raw['gender'] as String?, riderPhoto: profile?.avatarUrl),
        currency: _currency,
        pricing: ctx.pricing,
        timezone: ctx.timezone,
        cargoDescription: items,
        declaredValue: _declared,
        prohibitedAck: _ack,
        recipient: _recipient,
        parcelSize: _size,
        payer: _payer,
      );
      if (!mounted) return;
      setState(() {
        _items = const [];
        _note.clear();
        _offer = null;
        _declared = null;
        _ack = false;
        _recipient = null;
        _dropDetails.clear();
      });
      // Sent: nothing left to offer again.
      _saver.forget(_saved());
      _tabs.animateTo(1);
      showInfo(context, 'Request sent. Couriers will send you their offers.');
    } on DuplicateRideRequest catch (e) {
      if (mounted) showInfo(context, e.toString());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt as the vehicles, the settings and the tariffs arrive.
    ref.watch(courierVehiclesProvider);
    ref.watch(courierConfigProvider);
    ref.watch(rideOptionPlacesProvider);
    ref.watch(fareTariffsProvider);
    ref.watch(paymentChoicesProvider);
    final mine = _tabs.index == 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(mine ? 'My deliveries' : 'Courier'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(key: ValueKey('courier-tab-create'), text: 'Send a parcel'),
            Tab(key: ValueKey('courier-tab-mine'), text: 'My deliveries'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_form(context), const FreightRequestsList(kind: DeliveryKind.courier)],
      ),
    );
  }

  Widget _form(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final config = _config;
    final problem = courierDraftProblem(_draft, config);
    final vehicles = _vehicles;
    final v = _vehicle;
    final payments = ref.read(paymentChoicesProvider).value ?? builtInPayments;
    final payment = resolvePayment(_payment, payments);
    final look = DeliveryLook.of(context);
    Widget label(String text, {Widget? trailing}) => DeliverySectionLabel(text, trailing: trailing);
    Widget details(TextEditingController c, String key) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        key: ValueKey(key),
        controller: c,
        maxLength: 80,
        decoration: InputDecoration(
          labelText: 'Address details (floor, unit)',
          prefixIcon: const Icon(Icons.apartment_outlined),
          counterText: '',
          isDense: true,
          fillColor: look.field,
        ),
      ),
    );
    return Column(children: [
      Expanded(
        child: DeliveryChoiceTheme(
          child: ListView(
            key: const ValueKey('courier-form'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              label('Where to pick up'),
              FreightField(
                key: const ValueKey('courier-pickup'),
                label: 'Street, building',
                value: _pickup?.name,
                leading: const Icon(Icons.emoji_people, semanticLabel: 'Pickup'),
                onTap: () => _place(pickup: true),
              ),
              details(_pickupDetails, 'courier-pickup-details'),
              label('Where to deliver'),
              FreightField(
                key: const ValueKey('courier-drop'),
                label: 'Street, building',
                value: _drop?.name,
                leading: const Icon(Icons.flag, semanticLabel: 'Drop-off'),
                onTap: () => _place(pickup: false),
              ),
              details(_dropDetails, 'courier-drop-details'),
              const SizedBox(height: 8),
              FreightField(
                key: const ValueKey('courier-recipient'),
                label: 'Recipient',
                placeholder: "Recipient's phone number",
                value: _recipient == null
                    ? null
                    : [if (_recipient!.name.trim().isNotEmpty) _recipient!.name.trim(), _recipient!.phone.trim()].join(' · '),
                leading: const Icon(Icons.contacts_outlined),
                onTap: _chooseRecipient,
              ),
              label('What to deliver'),
              Row(children: [
                for (final p in ParcelSize.values)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: p == ParcelSize.l ? 0 : 8),
                      child: _SizeTile(
                        key: ValueKey('courier-size-${p.id}'),
                        size: p,
                        kg: config.kgOf(p),
                        selected: _size == p,
                        onTap: () => setState(() => _size = p),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final i in courierQuickItems)
                  FilterChip(
                    key: ValueKey('courier-item-$i'),
                    label: Text(_items.contains(i) ? i : '+ $i'),
                    selected: _items.contains(i),
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _items = toggleCourierItem(_items, i)),
                  ),
              ]),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('courier-note'),
                controller: _note,
                maxLength: courierNoteMax,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Optional',
                  hintText: 'What is inside, how to handle it',
                  fillColor: look.field,
                ),
              ),
              label('Vehicle'),
              if (vehicles.isEmpty)
                Text(
                  'No vehicle takes a ${_size.id} parcel yet.',
                  key: const ValueKey('courier-no-vehicle'),
                  style: t.textTheme.bodyMedium?.copyWith(color: muted),
                )
              else
                ListSearchFilter(
                  count: vehicles.length,
                  hint: 'Search vehicles',
                  builder: (context, q) => Column(children: [
                    for (final x in vehicles)
                      if (q.isEmpty || searchSelectMatches(x.shortName, q))
                        _VehicleRow(
                          key: ValueKey('courier-vehicle-${x.id}'),
                          vehicle: x,
                          price: switch (_recommendedFor(x)) {
                            final r? => '~ ${_money(r)}',
                            null => null,
                          },
                          selected: x.id == v?.id,
                          onTap: () => setState(() => _vehicleId = x.id),
                        ),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Couriers on this vehicle, or a bigger one, see your offer.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              const SizedBox(height: 12),
              FreightField(
                key: const ValueKey('courier-declared'),
                label: 'Value of your items',
                value: _declared == null ? null : _money(_declared!),
                onTap: _declare,
              ),
              CheckboxListTile(
                key: const ValueKey('courier-prohibited-ack'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _ack,
                onChanged: (x) => setState(() => _ack = x ?? false),
                title: const Text('My parcel has none of the prohibited items'),
                subtitle: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('courier-prohibited-list'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    onPressed: _showProhibited,
                    child: const Text('See the prohibited items'),
                  ),
                ),
              ),
              label('Who pays'),
              SegmentedButton<CourierPayer>(
                key: const ValueKey('courier-payer'),
                segments: [
                  for (final p in CourierPayer.values)
                    ButtonSegment(
                      value: p,
                      label: Text(p.label, key: ValueKey('courier-payer-${p.id}')),
                      icon: Icon(p == CourierPayer.sender ? Icons.person_outline : Icons.move_down),
                    ),
                ],
                selected: {_payer},
                onSelectionChanged: (x) => setState(() => _payer = x.first),
              ),
              const SizedBox(height: 8),
              if (_payer == CourierPayer.recipient)
                Text(
                  'Cash to the courier when the parcel arrives. You pay nothing now.',
                  key: const ValueKey('courier-payer-note'),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                )
              else
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final p in payments)
                    ChoiceChip(
                      key: ValueKey('courier-payment-${p.value}'),
                      avatar: MediaIcon(p.icon, fallback: paymentLook(p.kind).$1, size: 18),
                      label: Text(p.label),
                      selected: payment == p.value,
                      onSelected: (_) => setState(() => _payment = p.value),
                    ),
                ]),
              const SizedBox(height: 12),
              FreightField(
                key: const ValueKey('courier-offer'),
                label: 'Your price',
                value: _offer == null ? null : _money(_offer!),
                emphasis: true,
                placeholder: switch (_recommendedFor(v)) {
                  final r? => 'Offer your price, from ${_money(freightSuggestedRange(r).low)}',
                  null => 'Offer your price',
                },
                onTap: _offerPrice,
              ),
              if (config.codeChannels.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.pin_outlined, size: 20, color: t.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Delivery protection: a confirmation code. ${courierCodeHelp(config)}',
                        key: const ValueKey('courier-code-help'),
                        style: t.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      ),
      DeliveryFooter(
        buttonKey: const ValueKey('courier-create'),
        hintKey: const ValueKey('courier-create-hint'),
        label: 'Find a courier',
        busy: _booking,
        problem: problem,
        onPressed: _create,
      ),
    ]);
  }
}

/// One parcel size: S / M / L and its kilos.
class _SizeTile extends StatelessWidget {
  const _SizeTile({super.key, required this.size, required this.kg, required this.selected, required this.onTap});
  final ParcelSize size;
  final double kg;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The home vehicle bar's chosen card; the others the route sheet's grey.
    final t = Theme.of(context);
    final look = DeliveryLook.of(context);
    final fg = selected ? look.onChosen : look.onField;
    final radius = BorderRadius.circular(look.choiceRadius);
    return Material(
      color: selected ? look.chosen : look.field,
      shape: RoundedRectangleBorder(borderRadius: radius),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(children: [
            Icon(Icons.inventory_2_outlined, color: fg, size: 18 + ParcelSize.values.indexOf(size) * 4.0),
            const SizedBox(height: 4),
            Text(size.id, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: fg)),
            Text('up to ${trimKg(kg)} kg', style: t.textTheme.labelSmall?.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// A vehicle that carries the parcel: its picture or icon, name, limits and
/// the estimate for the trip; ticked when chosen.
class _VehicleRow extends StatelessWidget {
  const _VehicleRow({super.key, required this.vehicle, this.price, required this.selected, required this.onTap});
  final FreightVehicle vehicle;
  final String? price;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The home vehicle bar's chosen card.
    final t = Theme.of(context);
    final look = DeliveryLook.of(context);
    final ink = look.cardInk(t, selected);
    final muted = look.cardMuted(t, selected);
    final v = vehicle;
    final radius = BorderRadius.circular(look.choiceRadius);
    return Material(
      color: look.cardFill(selected),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            v.image == null
                ? SizedBox.square(dimension: 36, child: Icon(courierVehicleIcon(v), color: ink))
                : FreightVehicleImage(vehicle: v, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v.shortName, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: ink)),
                Text(
                  [?v.loadText, ?v.sizeText].join(' · '),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ]),
            ),
            if (price != null) Text(price!, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: ink)),
            const SizedBox(width: 8),
            Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, color: selected ? ink : muted),
          ]),
        ),
      ),
    );
  }
}
