// myGiG Delivery (migration 0332), the driver's side: "A delivery" on the
// myGiG sheet opens this. Three steps, as the approved prototype: what is
// being sent (type, a size the vehicle carries, weight, declared value,
// fragile, keep upright, a photo, the no-prohibited-items tick), the
// sender and the drop-offs (pickup here or elsewhere, the sender's phone
// checked as myGiG rides, up to the admin's most drop-offs, each with the
// recipient's phone and name), then the price and payment (who pays, how
// the sender pays, cash on delivery, "If it comes back" and how the sender
// accepts). The server prices it and checks everything again.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/mygig.dart';
import '../../core/mygig_delivery.dart';
import '../../data/freight_repository.dart' show freightCargoPhotoUploadProvider;
import '../../data/mygig_repository.dart';
import '../../data/photo_picker.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../partner/partner_trip_screen.dart' show tripFixProvider;
import '../ride/place_search.dart';
import 'mygig_delivery_settings.dart' show mygigDeliverySettingsPath;
import 'mygig_new_screen.dart' show MygigStop, openMygigWhatsApp;
import 'mygig_waiting_screen.dart';
import 'mygig_when.dart' show MygigNote;

const mygigDeliveryNewPath = '/drive/mygig/delivery';

/// A drop-off as the driver enters it.
class _Drop {
  MygigStop? place;
  final phone = TextEditingController();
  final name = TextEditingController();
  MygigLookup lookup = const MygigLookup();
  Timer? timer;

  void dispose() {
    timer?.cancel();
    phone.dispose();
    name.dispose();
  }
}

class MygigDeliveryNewScreen extends ConsumerStatefulWidget {
  const MygigDeliveryNewScreen({super.key});

  @override
  ConsumerState<MygigDeliveryNewScreen> createState() => _MygigDeliveryNewScreenState();
}

class _MygigDeliveryNewScreenState extends ConsumerState<MygigDeliveryNewScreen> {
  int _step = 0;
  LatLng? _origin;
  // What is being sent.
  String? _type;
  String _size = 'small';
  double _kg = 1;
  final _value = TextEditingController();
  bool _fragile = false;
  bool _upright = false;
  final _photos = <String>[];
  bool _noProhibited = false;
  bool _uploading = false;
  // Who and where.
  MygigStop? _pickup;
  final _senderPhone = TextEditingController();
  final _senderName = TextEditingController();
  MygigLookup _sender = const MygigLookup();
  Timer? _senderTimer;
  final _drops = <_Drop>[_Drop()];
  double? _km;
  double? _min;
  // The price.
  String _payer = 'sender';
  MygigPay _pay = MygigPay.cash;
  String? _businessId;
  bool _cod = false;
  final _codAmount = TextEditingController();
  String _retPayer = 'recipient';
  MygigWay? _way;
  MygigDeliveryQuote? _quote;
  String? _quoteError;
  Timer? _quoteTimer;
  int _quoteSeq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  @override
  void dispose() {
    _value.dispose();
    _senderPhone.dispose();
    _senderName.dispose();
    _codAmount.dispose();
    _senderTimer?.cancel();
    _quoteTimer?.cancel();
    for (final d in _drops) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _locate() async {
    final fix = await ref.read(tripFixProvider)();
    if (!mounted || fix == null) return;
    setState(() {
      _origin = fix;
      _pickup ??= MygigStop(name: 'Here', at: fix, here: true);
    });
  }

  MygigDeliveryConfig? get _config =>
      ref.read(mygigDeliveryConfigProvider(mygigAt(_origin?.latitude, _origin?.longitude))).value;

  double get _valueNum => double.tryParse(_value.text.trim()) ?? 0;
  double get _codNum => double.tryParse(_codAmount.text.trim()) ?? 0;
  bool get _inApp => mygigDeliveryInApp(registered: _sender.registered, pay: _pay);

  Future<void> _addPhoto() async {
    final picked = await ref.read(photoPickerProvider)(
        ref.read(photoCameraAvailableProvider) ? PhotoSource.camera : PhotoSource.gallery);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final path = await ref.read(freightCargoPhotoUploadProvider)(picked.bytes, picked.name);
      if (mounted) setState(() => _photos.add(path));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<MygigStop?> _search(String title) async {
    final pick = await showPlaceSearch(context, title: title, near: _origin);
    final p = pick?.place;
    if (p == null) return null;
    return MygigStop(name: p.name, address: p.address, at: p.point);
  }

  Future<void> _routeChanged() async {
    final pickup = _pickup;
    final places = [for (final d in _drops) d.place];
    if (pickup == null || places.any((p) => p == null)) return;
    try {
      final r = await ref.read(geoServiceProvider).route(pickup.at, places.last!.at,
          via: [for (final p in places.take(places.length - 1)) p!.at]);
      if (!mounted) return;
      setState(() {
        _km = r.distanceKm > 0 ? r.distanceKm : null;
        _min = r.distanceKm > 0 ? r.durationMin : null;
      });
    } catch (_) {}
    _requote();
  }

  void _lookup(String phone, void Function(MygigLookup) set, bool Function() still) {
    if (!mygigPhoneComplete(phone)) {
      setState(() => set(const MygigLookup()));
      return;
    }
    unawaited(() async {
      try {
        final l = await ref.read(mygigRepositoryProvider).lookup(phone, lat: _origin?.latitude, lng: _origin?.longitude);
        if (!mounted || !still()) return;
        setState(() => set(l));
        _fixPay();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }());
  }

  void _senderChanged(String v) {
    _senderTimer?.cancel();
    _senderTimer = Timer(const Duration(milliseconds: 450),
        () => _lookup(v, (l) => _sender = l, () => _senderPhone.text == v));
    if (!mygigPhoneComplete(v)) setState(() => _sender = const MygigLookup());
  }

  void _dropPhoneChanged(_Drop d, String v) {
    d.timer?.cancel();
    d.timer = Timer(const Duration(milliseconds: 450), () => _lookup(v, (l) => d.lookup = l, () => d.phone.text == v));
    if (!mygigPhoneComplete(v)) setState(() => d.lookup = const MygigLookup());
  }

  /// A payment, payer or COD that no longer fits goes back.
  void _fixPay() {
    final c = _config;
    if (!mygigDeliveryPayOptions(_sender).contains(_pay)) _pay = MygigPay.cash;
    if (_pay == MygigPay.business) {
      _businessId ??= _sender.businesses.firstOrNull?.id;
    } else {
      _businessId = null;
    }
    if (c != null) {
      if (_payer == 'recipient' && mygigRecipientPaysNo(s: c.settings, p: c.prefs, pay: _pay) != null) _payer = 'sender';
      if (_cod && mygigCodNo(s: c.settings, p: c.prefs, senderRegistered: _sender.registered) != null) _cod = false;
    }
    setState(() {});
    _requote();
  }

  Map<String, dynamic> _payload() => {
    'parcel': {
      'type': _type,
      'size': _size,
      'kg': _kg,
      'value': _valueNum,
      'fragile': _fragile,
      'upright': _upright,
      'photos': _photos,
      'noProhibited': _noProhibited,
    },
    'pickup': _pickup?.toJson(),
    'drops': [
      for (final d in _drops)
        if (d.place != null)
          {
            ...(d.place!.toJson()..remove('here')),
            'phone': mygigPhoneComplete(d.phone.text) ? '+${mygigPhoneDigits(d.phone.text)}' : d.phone.text,
            'recipient': d.name.text.trim(),
          },
    ],
    'km': ?_km,
    'min': ?_min,
    'sender': {
      'phone': mygigPhoneComplete(_senderPhone.text) ? '+${mygigPhoneDigits(_senderPhone.text)}' : null,
      'name': _senderName.text.trim(),
    },
    'registered': _sender.registered,
    'payer': _payer,
    'pay': _pay.name,
    'businessId': ?_businessId,
    'cod': _cod ? _codNum : 0,
    'retPayer': _retPayer,
    'way': _way?.name,
  };

  void _requote() {
    if (_step < 2) return;
    _quoteTimer?.cancel();
    _quoteTimer = Timer(const Duration(milliseconds: 250), () async {
      final seq = ++_quoteSeq;
      try {
        final q = await ref.read(mygigRepositoryProvider)
            .deliveryQuote(_payload(), lat: _origin?.latitude, lng: _origin?.longitude);
        if (!mounted || seq != _quoteSeq) return;
        setState(() {
          _quote = q;
          _quoteError = null;
        });
      } catch (e) {
        if (!mounted || seq != _quoteSeq) return;
        setState(() => _quoteError = '$e');
      }
    });
  }

  Future<void> _send() async {
    final way = _way;
    if (way == null) return;
    final sent = await ref.read(mygigRepositoryProvider)
        .deliveryCreate(_payload(), lat: _origin?.latitude, lng: _origin?.longitude);
    if (!mounted) return;
    if (way == MygigWay.whatsapp) await openMygigWhatsApp(sent);
    if (!mounted) return;
    await Navigator.of(context).push(AppPageRoute<void>(
      id: 'mygig.delivery-waiting',
      builder: (_) => MygigWaitingScreen(sent: sent),
    ));
  }

  String? _why(MygigDeliveryConfig c) => switch (_step) {
    0 => mygigParcelProblem(
        s: c.settings,
        vehicle: c.vehicle,
        vehicleName: c.vehicleName,
        type: _type,
        size: _size,
        kg: _kg,
        value: _valueNum,
        photos: _photos.length,
        noProhibited: _noProhibited,
        offTypes: c.prefs.offTypes,
      ),
    1 => _pickup == null
        ? 'Finding where you are…'
        : mygigRouteProblem(
            senderPhoneRequired: c.settings.senderPhoneRequired,
            senderPhone: _senderPhone.text,
            sender: _sender,
            senderName: _senderName.text,
            drops: [
              for (final d in _drops)
                MygigDropDraft(placeSet: d.place != null, phone: d.phone.text, lookup: d.lookup, name: d.name.text),
            ],
          ),
    _ => mygigDeliverySendProblem(
        quote: _quote,
        codOn: _cod,
        codAmount: _codNum,
        codMax: c.settings.codMax,
        way: _way,
        inApp: _inApp,
        hasPhone: mygigPhoneComplete(_senderPhone.text),
      ),
  };

  @override
  Widget build(BuildContext context) {
    final at = mygigAt(_origin?.latitude, _origin?.longitude);
    final async = ref.watch(mygigDeliveryConfigProvider(at));
    final ride = ref.watch(mygigConfigProvider(at)).value;
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(switch (_step) { 0 => 'myGiG delivery', 1 => 'Sender and drop-offs', _ => 'Price and payment' }),
          actions: [
            IconButton(
              key: const ValueKey('mygig-delivery-tune'),
              tooltip: 'Delivery settings',
              icon: const Icon(Icons.tune),
              onPressed: () async {
                await context.push(mygigDeliverySettingsPath);
                if (mounted) _requote();
              },
            ),
          ],
        ),
        body: AsyncView(
          value: async,
          onRetry: () => ref.invalidate(mygigDeliveryConfigProvider),
          data: (c) {
            final why = _why(c);
            final t = Theme.of(context);
            return Column(children: [
              Expanded(
                child: ResponsiveCenter(
                  maxWidth: 640,
                  child: ListView(
                    key: ValueKey('mygig-delivery-step-$_step'),
                    padding: const EdgeInsets.all(16),
                    children: switch (_step) {
                      0 => _parcel(t, c),
                      1 => _route(t, c),
                      _ => _price(t, c, ride),
                    },
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (why != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(why, key: const ValueKey('mygig-delivery-why'), textAlign: TextAlign.center,
                            style: t.textTheme.bodySmall),
                      ),
                    BusyButton.filled(
                      key: const ValueKey('mygig-delivery-next'),
                      icon: Icon(_step == 2 ? Icons.send : Icons.arrow_forward),
                      onPressed: why != null
                          ? null
                          : _step < 2
                          ? () async {
                              setState(() => _step++);
                              if (_step == 2) {
                                _fixPay();
                                await _routeChanged();
                              }
                            }
                          : _send,
                      child: Text(switch (_step) {
                        0 => 'Next: sender and drop-offs',
                        1 => 'Next: price and payment',
                        _ => _way == MygigWay.here ? 'Show the sender' : 'Send to the sender',
                      }),
                    ),
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _sec(ThemeData t, IconData i, String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Row(children: [
      Icon(i, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Text(title, style: t.textTheme.titleSmall)),
      ?trailing,
    ]),
  );

  List<Widget> _parcel(ThemeData t, MygigDeliveryConfig c) {
    final s = c.settings;
    final maxKg = s.maxKg(c.vehicle);
    return [
      _sec(t, Icons.category_outlined, 'What is it?'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final type in s.itemTypes)
          ChoiceChip(
            key: ValueKey('mygig-delivery-type-$type'),
            label: Text(type,
                style: c.prefs.offTypes.contains(type) ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
            selected: _type == type,
            onSelected: c.prefs.offTypes.contains(type) ? null : (_) => setState(() => _type = type),
          ),
      ]),
      if (c.prefs.offTypes.isNotEmpty)
        Text('Crossed out: you don’t take these (Delivery settings).', style: t.textTheme.bodySmall),
      _sec(t, Icons.inventory_2_outlined, 'Size', trailing: Text('Your ${c.vehicleName.toLowerCase()}', style: t.textTheme.bodySmall)),
      Card(
        margin: EdgeInsets.zero,
        child: RadioGroup<String>(
          groupValue: _size,
          onChanged: (v) => setState(() => _size = v ?? 'small'),
          child: Column(children: [
            for (final (k, name, hint) in mygigDeliverySizes)
              RadioListTile<String>(
                key: ValueKey('mygig-delivery-size-$k'),
                value: k,
                enabled: s.sizeFits(k, c.vehicle),
                title: Text('$name${c.card.extra(k) > 0 ? ' · +${mygigMoney(c.card.extra(k))}' : ''}'),
                subtitle: Text(s.sizeFits(k, c.vehicle) ? hint : '$hint · ${s.needsText(k)}'),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        const Icon(Icons.scale_outlined),
        const SizedBox(width: 8),
        Text('Weight', style: t.textTheme.titleSmall),
        const Spacer(),
        IconButton(
          tooltip: 'Lighter',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: _kg > 1 ? () => setState(() => _kg--) : null,
        ),
        Text('${_kg.round()} kg', key: const ValueKey('mygig-delivery-kg'), style: t.textTheme.titleMedium),
        IconButton(
          key: const ValueKey('mygig-delivery-kg-plus'),
          tooltip: 'Heavier',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: _kg < maxKg ? () => setState(() => _kg++) : null,
        ),
      ]),
      TextField(
        key: const ValueKey('mygig-delivery-value'),
        controller: _value,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: const InputDecoration(prefixText: 'RM ', labelText: 'Declared value', hintText: '0.00'),
        onChanged: (_) => setState(() {}),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('Covered up to ${mygigMoney(s.coverFree)} for a ${mygigMoney(s.coverFee)} cover fee; above that, '
            '${s.coverPct}% of the value. Up to ${mygigMoney(s.maxValue)}.', style: t.textTheme.bodySmall),
      ),
      SwitchListTile(
        key: const ValueKey('mygig-delivery-fragile'),
        contentPadding: EdgeInsets.zero,
        value: _fragile,
        title: const Text('Fragile'),
        subtitle: Text('Handle with care · +${mygigMoney(c.card.fragile)}'),
        onChanged: (v) => setState(() => _fragile = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _upright,
        title: const Text('Keep upright'),
        subtitle: const Text('Food, drinks, plants'),
        onChanged: (v) => setState(() => _upright = v),
      ),
      _sec(t, Icons.photo_camera_outlined, 'Photo of the item'),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final (i, _) in _photos.indexed)
          Chip(avatar: const Icon(Icons.image_outlined), label: Text('Photo ${i + 1}')),
        OutlinedButton.icon(
          key: const ValueKey('mygig-delivery-photo'),
          onPressed: _uploading || _photos.length >= 6 ? null : _addPhoto,
          icon: const Icon(Icons.add_a_photo_outlined),
          label: Text(_uploading ? 'Saving…' : _photos.isEmpty ? 'Take a photo' : 'Add another'),
        ),
      ]),
      const SizedBox(height: 8),
      CheckboxListTile(
        key: const ValueKey('mygig-delivery-prohibited'),
        contentPadding: EdgeInsets.zero,
        value: _noProhibited,
        title: const Text('The sender says there are no prohibited items'),
        subtitle: Text(s.prohibited.join(' · ')),
        onChanged: (v) => setState(() => _noProhibited = v ?? false),
      ),
    ];
  }

  Widget _lookupNote(ThemeData t, MygigLookup l, {required bool sender}) {
    if (l.state == MygigLookupState.short) return const SizedBox.shrink();
    if (l.state == MygigLookupState.blocked) {
      return const MygigNote(icon: Icons.block, title: 'You blocked this number', body: 'Unblock it in myGiG settings first.', bad: true);
    }
    if (l.registered) {
      return MygigNote(
        icon: l.state == MygigLookupState.latest ? Icons.verified : Icons.system_update,
        title: l.name ?? 'Registered',
        body: l.state == MygigLookupState.latest
            ? 'Registered, latest app. No name needed; ${sender ? 'can accept in the app' : 'tracks it in the app'}.'
            : 'Registered, older app. No name needed; gets a link by WhatsApp or SMS.',
        ok: l.state == MygigLookupState.latest,
        warn: l.state == MygigLookupState.old,
      );
    }
    return const MygigNote(icon: Icons.person_add_alt, title: 'Not registered', body: 'Enter the name. Gets a link by WhatsApp or SMS.');
  }

  List<Widget> _route(ThemeData t, MygigDeliveryConfig c) {
    final s = c.settings;
    return [
      _sec(t, Icons.trip_origin, 'Pickup'),
      ListTile(
        key: const ValueKey('mygig-delivery-pickup'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.trip_origin, color: t.colorScheme.primary),
        title: Text(_pickup == null ? 'Finding where you are…' : _pickup!.here ? 'Here' : _pickup!.name),
        subtitle: Text(_pickup?.here ?? true ? 'Where you are now' : 'Another place'),
        trailing: TextButton(
          onPressed: () async {
            final p = await _search('Pickup location');
            if (p != null && mounted) setState(() => _pickup = p);
          },
          child: const Text('Change'),
        ),
      ),
      _sec(t, Icons.person_outline, 'Sender',
          trailing: Text(s.senderPhoneRequired ? 'Phone required' : 'Phone optional', style: t.textTheme.bodySmall)),
      TextField(
        key: const ValueKey('mygig-delivery-sender-phone'),
        controller: _senderPhone,
        keyboardType: TextInputType.phone,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 \-]'))],
        decoration: const InputDecoration(prefixText: '+60 ', labelText: 'Sender’s phone', hintText: '12 345 6789'),
        onChanged: _senderChanged,
      ),
      _lookupNote(t, _sender, sender: true),
      if (_sender.needsName || (_senderPhone.text.trim().isEmpty && !s.senderPhoneRequired))
        TextField(
          key: const ValueKey('mygig-delivery-sender-name'),
          controller: _senderName,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Sender’s name (required)'),
          onChanged: (_) => setState(() {}),
        ),
      for (final (i, d) in _drops.indexed)
        Card(
          key: ValueKey('mygig-delivery-drop-$i'),
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.location_on, color: t.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(child: Text('Drop-off${_drops.length > 1 ? ' ${i + 1}' : ''}', style: t.textTheme.titleSmall)),
                if (_drops.length > 1)
                  IconButton(
                    tooltip: 'Remove drop-off ${i + 1}',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _drops.removeAt(i).dispose()),
                  ),
              ]),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(d.place?.name ?? 'Choose the place'),
                trailing: const Icon(Icons.search),
                onTap: () async {
                  final p = await _search('Drop-off${_drops.length > 1 ? ' ${i + 1}' : ''}');
                  if (p != null && mounted) setState(() => d.place = p);
                },
              ),
              TextField(
                key: ValueKey('mygig-delivery-drop-phone-$i'),
                controller: d.phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 \-]'))],
                decoration: const InputDecoration(prefixText: '+60 ', labelText: 'Recipient’s phone', hintText: '12 345 6789'),
                onChanged: (v) => _dropPhoneChanged(d, v),
              ),
              _lookupNote(t, d.lookup, sender: false),
              if (d.lookup.needsName)
                TextField(
                  key: ValueKey('mygig-delivery-drop-name-$i'),
                  controller: d.name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Recipient’s name (required)'),
                  onChanged: (_) => setState(() {}),
                ),
            ]),
          ),
        ),
      if (_drops.length < s.maxDrops)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('mygig-delivery-add-drop'),
            onPressed: () => setState(() => _drops.add(_Drop())),
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Add another drop-off'),
          ),
        )
      else
        Text('Up to ${s.maxDrops} drop-offs.', style: t.textTheme.bodySmall),
    ];
  }

  List<Widget> _price(ThemeData t, MygigDeliveryConfig c, MygigConfig? ride) {
    final s = c.settings;
    final q = _quote;
    final recipientNo = mygigRecipientPaysNo(s: s, p: c.prefs, pay: _pay);
    final codNo = mygigCodNo(s: s, p: c.prefs, senderRegistered: _sender.registered);
    final hasPhone = mygigPhoneComplete(_senderPhone.text);
    final ways = ride == null
        ? const <MygigWay>[]
        : mygigWays(ride.settings, _sender.registered ? _sender.state : MygigLookupState.none, hasPhone: hasPhone)
            .where((w) => _pay != MygigPay.family || w == MygigWay.app)
            .toList();
    if (_way != null && !ways.contains(_way)) _way = null;
    final senderShown = _sender.name ?? (_senderName.text.trim().isEmpty ? 'the sender' : _senderName.text.trim().split(' ').first);
    return [
      Row(children: [
        Expanded(
          child: Text(q == null ? 'Working out the price…' : '${q.km.toStringAsFixed(1)} km · ${c.vehicleName}',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
        Text(q == null ? '' : mygigMoney(q.total), key: const ValueKey('mygig-delivery-total'), style: t.textTheme.headlineSmall),
      ]),
      if (_quoteError != null) Text(_quoteError!, style: TextStyle(color: t.colorScheme.error)),
      if (q != null) MygigDeliveryLines(quote: q, size: _size, kg: _kg, freeKg: c.card.freeKg),
      if (q != null && q.own) Text('Your own delivery rates (Delivery settings).', style: t.textTheme.bodySmall),
      Text('Waiting over ${c.waitFree.round()} min at the pickup or a drop-off is ${mygigMoney(c.waitPerMin)} a minute.',
          style: t.textTheme.bodySmall),
      _sec(t, Icons.payments_outlined, 'Who pays the delivery'),
      SegmentedButton<String>(
        key: const ValueKey('mygig-delivery-payer'),
        segments: [
          const ButtonSegment(value: 'sender', label: Text('Sender')),
          ButtonSegment(value: 'recipient', label: const Text('Recipient'), enabled: recipientNo == null),
        ],
        selected: {_payer},
        onSelectionChanged: (v) {
          setState(() => _payer = v.first);
          _requote();
        },
      ),
      if (recipientNo != null) Text(recipientNo, style: t.textTheme.bodySmall),
      const SizedBox(height: 8),
      Text(_payer == 'recipient' ? 'Sender’s account for a return trip' : 'Sender pays by', style: t.textTheme.bodySmall),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in mygigDeliveryPayOptions(_sender))
          ChoiceChip(
            key: ValueKey('mygig-delivery-pay-${p.name}'),
            label: Text(mygigPayName(p, familyHost: _sender.familyHost, business: _sender.businesses.firstOrNull?.name)),
            selected: _pay == p,
            onSelected: (_) {
              setState(() => _pay = p);
              _fixPay();
            },
          ),
      ]),
      if (_payer == 'recipient' && q != null)
        MygigNote(
          icon: Icons.info_outline,
          title: 'Recipient pays ${mygigMoney(q.total)} on delivery',
          body: 'Guaranteed by ${_inApp ? mygigPayName(_pay) : 'the sender’s deposit'}: if the recipient doesn’t pay, the sender does.',
        )
      else if (_pay == MygigPay.cash)
        Text('Collect the cash at pickup, before you go.', style: t.textTheme.bodySmall)
      else if (_pay == MygigPay.link)
        Text('The sender pays by card, FPX or DuitNow before you pick up.', style: t.textTheme.bodySmall),
      _sec(t, Icons.point_of_sale, 'Cash on delivery',
          trailing: Switch(
            key: const ValueKey('mygig-delivery-cod'),
            value: _cod,
            onChanged: codNo != null
                ? null
                : (v) {
                    setState(() => _cod = v);
                    _requote();
                  },
          )),
      if (codNo != null) Text(codNo, style: t.textTheme.bodySmall),
      if (_cod) ...[
        TextField(
          key: const ValueKey('mygig-delivery-cod-amount'),
          controller: _codAmount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: const InputDecoration(prefixText: 'RM ', labelText: 'Collect from the recipient', hintText: '0.00'),
          onChanged: (_) {
            setState(() {});
            _requote();
          },
        ),
        Text('For the item, on top of any delivery fare. It goes to $senderShown’s GET.wallet after delivery, less the '
            '${s.codFeePct}% COD fee${q == null ? '' : ' (${mygigMoney(q.codFee)})'}.', style: t.textTheme.bodySmall),
      ],
      _sec(t, Icons.keyboard_return, 'If it comes back'),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Nobody there, or refused', style: t.textTheme.titleSmall),
            Text(q == null
                ? 'The sender pays ${c.prefs.returnPct}% of the return fare.'
                : 'The sender pays ${q.retPct}% of the return fare, up to ${mygigMoney(q.maxFail)}. '
                    '${q.deposit != null ? mygigDepositText(q.deposit!) : 'Charged to ${mygigPayName(_pay)} only if it happens.'}',
                key: const ValueKey('mygig-delivery-failed-terms'), style: t.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('The recipient asks to send it back', style: t.textTheme.titleSmall),
            Text('The full return fare${q == null ? '' : ' (up to ${mygigMoney(q.maxReturn)})'} is paid by:', style: t.textTheme.bodySmall),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              key: const ValueKey('mygig-delivery-ret-payer'),
              segments: const [
                ButtonSegment(value: 'recipient', label: Text('Recipient')),
                ButtonSegment(value: 'sender', label: Text('Sender')),
              ],
              selected: {_retPayer},
              onSelectionChanged: (v) => setState(() => _retPayer = v.first),
            ),
            const SizedBox(height: 6),
            Text('Whoever pays, pays before the return starts. $senderShown must acknowledge every return before it leaves.',
                style: t.textTheme.bodySmall),
          ]),
        ),
      ),
      _sec(t, Icons.how_to_reg_outlined, 'How the sender accepts'),
      Card(
        margin: EdgeInsets.zero,
        child: RadioGroup<MygigWay>(
          groupValue: _way,
          onChanged: (w) => setState(() => _way = w),
          child: Column(children: [
            for (final w in ways)
              RadioListTile<MygigWay>(
                key: ValueKey('mygig-delivery-way-${w.name}'),
                value: w,
                title: Text(w == MygigWay.here ? 'Show on this phone' : w.label),
              ),
          ]),
        ),
      ),
    ];
  }
}

/// The price's lines (the driver's screen, the sender's page).
class MygigDeliveryLines extends StatelessWidget {
  const MygigDeliveryLines({super.key, required this.quote, required this.size, required this.kg, required this.freeKg});
  final MygigDeliveryQuote quote;
  final String size;
  final double kg;
  final double freeKg;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(key: const ValueKey('mygig-delivery-lines'), children: [
        for (final (label, amount) in quote.lines(sizeKey: size, weight: kg, freeKg: freeKg))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(label, style: t.textTheme.bodySmall)),
              Text(mygigMoney(amount), style: t.textTheme.bodySmall),
            ]),
          ),
        if (!quote.showTax && quote.tax > 0)
          Align(alignment: Alignment.centerLeft, child: Text('Price includes service tax', style: t.textTheme.bodySmall)),
      ]),
    );
  }
}

/// Opens a delivery's pay link (the server's part [request]), signed in or
/// with the link's [token]; tells the person when no gateway is set.
Future<void> openMygigDeliveryPay(BuildContext context, WidgetRef ref, String request, {String? token}) async {
  try {
    final url = await ref.read(mygigRepositoryProvider).payLinkUrl(request, token: token);
    if (url == null) throw const MygigError('Paying by link isn’t available right now. Pay in cash, or try again later.');
    await launchMygigUrl(url);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Opens a hosted payment page.
Future<void> launchMygigUrl(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}
