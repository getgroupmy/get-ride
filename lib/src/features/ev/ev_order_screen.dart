import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/commerce/commerce_widgets.dart' show StoredImage;
import '../../admin/screens/commerce/ev_orders.dart';
import '../../admin/screens/meterapp/pick_image.dart';
import '../../core/ev_wizard.dart';
import '../../data/ev_order_repository.dart';
import '../../providers.dart';

/// Book TEKSI EV (Expo `app/teksi-ev.tsx`): the customer's nine-step car
/// order, from choosing a model to accepting the handover. The order is
/// created when the order fee is confirmed and patched step by step; it is
/// resumed on any later visit.
///
/// No money changes hands in the app: the order fee, a cash balance and a
/// leasing add-on are recorded as owed, and the back office marks each one
/// received once it has collected it.
class EvOrderScreen extends ConsumerStatefulWidget {
  const EvOrderScreen({super.key});

  @override
  ConsumerState<EvOrderScreen> createState() => _EvOrderScreenState();
}

class _EvOrderScreenState extends ConsumerState<EvOrderScreen> {
  int _step = 0;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;

  String? _orderId;
  Map<String, dynamic>? _order;

  // Choices made before the order exists.
  bool _inventoryMode = false;
  String? _vehicleId;
  String? _unitId;
  String? _exterior;
  String? _interior;
  String _wheel = evDefaultWheel;
  bool _wheelsUnlocked = false;
  final Set<String> _accessoryIds = {};

  // Ownership form.
  String _ownerType = 'self';
  String _idType = 'national';
  String _idCountry = 'Malaysia';
  final _fields = <String, TextEditingController>{
    for (final k in ['fullName', 'idNumber', 'address', 'relationship', 'companyName', 'companyRegNo', 'companyAddress'])
      k: TextEditingController(),
  };

  final _plate = TextEditingController();
  final _addon = TextEditingController();
  final _daCode = TextEditingController();

  EvOrderRepository get _repo => ref.read(evOrderRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _resume();
  }

  @override
  void dispose() {
    for (final c in [..._fields.values, _plate, _addon, _daCode]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Picks up the order this phone was working on, else the account's newest
  /// unfinished one.
  Future<void> _resume() async {
    try {
      String? id = await _repo.activeOrderId();
      EvOrder? found = id == null ? null : await _repo.order(id);
      final finished = found != null && resumableEvOrder([found]) == null;
      if (found == null || finished) {
        if (id != null) await _repo.rememberActive(null);
        final orders = await _repo.myOrders();
        id = resumableEvOrder(orders);
        found = orders.where((o) => o.id == id).firstOrNull;
        if (id != null) await _repo.rememberActive(id);
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (found != null) {
          _orderId = found.id;
          _applyOrder(found.values);
          _step = evStepKeys.indexOf(deriveEvOrderStep(found.values));
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Could not load your order. Check your connection and try again.';
        });
      }
    }
  }

  /// Fills the forms from a stored order.
  void _applyOrder(Map<String, dynamic> v) {
    _order = v;
    _ownerType = '${v['ownerType'] ?? ''}'.isEmpty ? _ownerType : '${v['ownerType']}';
    final idType = '${v['ownerIdType'] ?? ''}';
    if (idType.isNotEmpty) _idType = idType.contains('passport') ? 'passport' : 'national';
    if ('${v['ownerIdCountry'] ?? ''}'.isNotEmpty) _idCountry = '${v['ownerIdCountry']}';
    for (final (field, key) in const [
      ('fullName', 'ownerFullName'),
      ('idNumber', 'ownerIdNumber'),
      ('address', 'ownerAddress'),
      ('relationship', 'ownerRelationship'),
      ('companyName', 'companyName'),
      ('companyRegNo', 'companyRegNo'),
      ('companyAddress', 'companyAddress'),
    ]) {
      if (_fields[field]!.text.isEmpty) _fields[field]!.text = '${v[key] ?? ''}';
    }
    if (_plate.text.isEmpty) _plate.text = '${v['plateNumber'] ?? ''}';
    if (_addon.text.isEmpty && toNumOrNull(v['leasingAddonAmount']) != null) _addon.text = '${v['leasingAddonAmount']}';
  }

  Future<void> _reload() async {
    final id = _orderId;
    if (id == null) return;
    final o = await _repo.order(id);
    if (o != null && mounted) setState(() => _applyOrder(o.values));
  }

  /// Writes [patch] onto the order.
  Future<bool> _save(Map<String, dynamic> patch, {String? done}) async {
    final id = _orderId;
    if (id == null) return false;
    setState(() => _busy = true);
    try {
      final merged = await _repo.patch(id, patch);
      if (!mounted) return true;
      setState(() => _order = merged);
      if (done != null) _say(done);
      return true;
    } catch (e) {
      _say('Could not save: $e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- Derived -------------------------------------------------------------

  Map<String, EvVehicle> _vehicles(EvCatalog c) => {for (final e in c.vehicles) e.id: EvVehicle(e.id, e.values)};

  List<EvInventoryUnit> _units(EvCatalog c) {
    final vehicles = _vehicles(c);
    return [for (final e in c.inventory) EvInventoryUnit(e.id, e.values, vehicles)];
  }

  EvInventoryUnit? _unit(EvCatalog c) => _units(c).where((u) => u.id == _unitId).firstOrNull;

  EvVehicle? _vehicle(EvCatalog c) => _inventoryMode ? _unit(c)?.vehicle : _vehicles(c)[_vehicleId];

  List<EvPricedItem> _extras(EvCatalog c) {
    if (_inventoryMode) {
      final u = _unit(c);
      return [...?u?.includedFeatures, ...?u?.includedAccessories];
    }
    return [...?_vehicle(c)?.accessories.where((a) => _accessoryIds.contains(a.id))];
  }

  ({double amount, String currency, String country}) _fee(EvCatalog c) {
    final country = _inventoryMode ? _unit(c)?.country : _vehicle(c)?.country;
    final account = ref.read(profileProvider).value?.raw['nationality'];
    return resolveOrderFee(
      [for (final f in c.fees) f.values],
      (country ?? '').isNotEmpty ? country : (account is String && account.isNotEmpty ? account : _idCountry),
    );
  }

  bool _canProceed(EvCatalog c) {
    final v = _order;
    return switch (evStepKeys[_step]) {
      'model' => v != null || (_inventoryMode ? _unitId != null : _vehicleId != null),
      'specification' => v != null || _inventoryMode || (_exterior != null && _interior != null),
      'deposit' => v != null,
      'ownership' => v != null && isEvOwnershipConfirmed(v),
      'plate' => v != null && isEvPlateAnswered(v),
      'financing' => v != null && isEvFinancingComplete(v),
      'advisor' => '${v?['advisorId'] ?? ''}'.isNotEmpty,
      'schedule' => '${v?['deliveryDate'] ?? ''}'.isNotEmpty,
      _ => false,
    };
  }

  // ---- Layout --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(evCatalogProvider);
    ref.watch(profileProvider);
    final key = evStepKeys[_step];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Book TEKSI EV'),
        actions: [
          if (_orderId != null)
            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _busy ? null : _reload),
        ],
      ),
      body: _loading || catalog.isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null || catalog.hasError
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_loadError ?? 'Could not load the TEKSI EV catalogue.')))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _progress(),
                  Expanded(
                    child: ListView(padding: const EdgeInsets.all(16), children: [
                      Text(evStepTitles[key]!, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 12),
                      ..._stepBody(key, catalog.value!),
                    ]),
                  ),
                ]),
      // In the bottom bar, so a message pops up above the buttons rather than
      // over them.
      bottomNavigationBar: catalog.value == null || _loading || _loadError != null ? null : _footer(catalog.value!),
    );
  }

  Widget _progress() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Step ${_step + 1} of ${evStepKeys.length}', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: (_step + 1) / evStepKeys.length),
        ]),
      );

  Widget _footer(EvCatalog c) {
    final last = _step == evStepKeys.length - 1;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          OutlinedButton(onPressed: _step == 0 || _busy ? null : () => setState(() => _step--), child: const Text('Back')),
          const Spacer(),
          if (!last)
            FilledButton(
              onPressed: _busy || !_canProceed(c) ? null : () => setState(() => _step++),
              child: const Text('Continue'),
            ),
        ]),
      ),
    );
  }

  List<Widget> _stepBody(String key, EvCatalog c) => switch (key) {
        'model' => _modelStep(c),
        'specification' => _specStep(c),
        'deposit' => _depositStep(c),
        'ownership' => _ownershipStep(),
        'plate' => _plateStep(),
        'financing' => _financingStep(c),
        'advisor' => _advisorStep(c),
        'schedule' => _scheduleStep(),
        _ => _deliveryStep(c),
      };

  /// Once the order exists its build is fixed: the first two steps show it.
  List<Widget> _placedSummary() {
    final v = _order!;
    return [
      Card(
        child: ListTile(
          leading: const Icon(Icons.electric_car_outlined),
          title: Text('${v['vehicle'] ?? 'TEKSI EV'}'),
          subtitle: Text([
            '${v['exteriorColor'] ?? ''}',
            '${v['interiorColor'] ?? ''}',
            '${v['wheels'] ?? ''}',
            if ('${v['accessories'] ?? ''}'.isNotEmpty) '${v['accessories']}',
          ].where((s) => s.isNotEmpty).join(' · ')),
          trailing: Text(evMoney(toNumOrNull(v['total']) ?? 0)),
        ),
      ),
      const Text('Your order has been placed, so its build can no longer be changed here. '
          'Contact TEKSI if you need to change it.'),
    ];
  }

  // ---- 1. Model --------------------------------------------------------------

  List<Widget> _modelStep(EvCatalog c) {
    if (_order != null) return _placedSummary();
    final vehicles = _vehicles(c).values.toList();
    final units = _units(c);
    return [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Custom build')),
          ButtonSegment(value: true, label: Text('In stock')),
        ],
        selected: {_inventoryMode},
        onSelectionChanged: (s) => setState(() => _inventoryMode = s.first),
      ),
      const SizedBox(height: 12),
      if (_inventoryMode) ...[
        const Text('Ready units, assigned with a VIN, for faster delivery.'),
        if (units.isEmpty) const _Empty('No units in stock right now. Try a custom build.'),
        for (final u in units)
          _choice(
            selected: u.id == _unitId,
            image: u.vehicle?.imageUri,
            title: u.name,
            subtitle: (u.vehicle?.price ?? 0) > 0
                ? 'From ${evMoney(u.vehicle!.price)}${u.vehicle!.tax > 0 ? ' + ${evMoney(u.vehicle!.tax)} tax' : ''}'
                : 'VIN ${u.vin.isEmpty ? '—' : u.vin}',
            badge: 'In stock',
            onTap: () => setState(() {
              _unitId = u.id;
              _wheel = u.factoryWheels;
              _wheelsUnlocked = false;
            }),
          ),
      ] else ...[
        if (vehicles.isEmpty) const _Empty('No models are available yet.'),
        for (final v in vehicles)
          _choice(
            selected: v.id == _vehicleId,
            image: v.imageUri,
            title: v.name,
            subtitle: v.price > 0
                ? 'From ${evMoney(v.price)}${v.tax > 0 ? ' · tax ${evMoney(v.tax)}' : ''}'
                : 'Configure your build',
            onTap: () => setState(() {
              if (_vehicleId != v.id) {
                _exterior = v.exteriorColours.firstOrNull?.name;
                _interior = v.interiorColours.firstOrNull?.name;
                _accessoryIds.clear();
              }
              _vehicleId = v.id;
            }),
          ),
      ],
    ];
  }

  Widget _choice({
    required bool selected,
    String? image,
    required String title,
    required String subtitle,
    String? badge,
    required VoidCallback onTap,
  }) =>
      Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: ListTile(
          leading: SizedBox(
            width: 72,
            child: (image ?? '').isEmpty
                ? const Icon(Icons.electric_car_outlined, size: 36)
                : ClipRRect(borderRadius: BorderRadius.circular(8), child: StoredImage(image!, width: 72, height: 48)),
          ),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: badge == null ? (selected ? const Icon(Icons.check_circle) : null) : Chip(label: Text(badge)),
          onTap: onTap,
        ),
      );

  // ---- 2. Specification -------------------------------------------------------

  List<Widget> _specStep(EvCatalog c) {
    if (_order != null) return _placedSummary();
    final vehicle = _vehicle(c);
    final unit = _inventoryMode ? _unit(c) : null;
    final price = evPriceBreakdown(vehicle, _extras(c));
    return [
      if ((vehicle?.gallery ?? const []).isNotEmpty)
        SizedBox(
          height: 140,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final g in vehicle!.gallery)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(8), child: StoredImage(g.url, width: 180, height: 116)),
                  Text(g.label, style: Theme.of(context).textTheme.labelSmall),
                ]),
              ),
          ]),
        ),
      if (unit != null) ...[
        _Facts({
          'Exterior': unit.exteriorColour,
          'Interior': unit.interiorColour,
          'VIN': unit.vin,
          if (unit.includedFeatures.isNotEmpty) 'Features': unit.includedFeatures.map((f) => f.name).join(', '),
          if (unit.includedAccessories.isNotEmpty) 'Accessories': unit.includedAccessories.map((a) => a.name).join(', '),
        }),
        const SizedBox(height: 8),
        _section('Wheels'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Factory fitted: ${unit.factoryWheels}'),
          subtitle: const Text('Change the wheels (they will be re-fitted before delivery)'),
          value: _wheelsUnlocked,
          onChanged: (v) => setState(() {
            _wheelsUnlocked = v;
            if (!v) _wheel = unit.factoryWheels;
          }),
        ),
        if (_wheelsUnlocked) _chips({unit.factoryWheels, ...evWheelOptions}.toList(), _wheel, (w) => setState(() => _wheel = w)),
      ] else if (vehicle != null) ...[
        _section('Exterior colour'),
        _colourChips(vehicle.exteriorColours, _exterior, (n) => setState(() => _exterior = n)),
        _section('Interior colour'),
        _colourChips(vehicle.interiorColours, _interior, (n) => setState(() => _interior = n)),
        _section('Wheels'),
        _chips(evWheelOptions, _wheel, (w) => setState(() => _wheel = w)),
        if (vehicle.accessories.isNotEmpty) ...[
          _section('Accessories'),
          for (final a in vehicle.accessories)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(a.name),
              subtitle: a.price > 0 ? Text('+ ${evMoney(a.price)}') : null,
              value: _accessoryIds.contains(a.id),
              onChanged: (on) => setState(() => on == true ? _accessoryIds.add(a.id) : _accessoryIds.remove(a.id)),
            ),
        ],
      ],
      const SizedBox(height: 12),
      _Facts({
        'Base price': evMoney(price.base),
        'Tax': evMoney(price.tax),
        'Options': evMoney(price.extras),
        'Estimated total': evMoney(price.total),
      }),
    ];
  }

  Widget _colourChips(List<EvColour> colours, String? selected, ValueChanged<String> onPick) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in colours)
            ChoiceChip(
              avatar: _swatch(c.code),
              label: Text(c.name),
              selected: c.name == selected,
              onSelected: (_) => onPick(c.name),
            ),
        ],
      );

  Widget? _swatch(String code) {
    final hex = code.replaceFirst('#', '');
    final value = int.tryParse(hex.length == 6 ? 'FF$hex' : '', radix: 16);
    if (value == null) return null;
    return CircleAvatar(backgroundColor: Color(value), radius: 8);
  }

  Widget _chips(List<String> options, String selected, ValueChanged<String> onPick) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final o in options) ChoiceChip(label: Text(o), selected: o == selected, onSelected: (_) => onPick(o)),
        ],
      );

  // ---- 3. Order fee -----------------------------------------------------------

  List<Widget> _depositStep(EvCatalog c) {
    final v = _order;
    if (v != null) {
      final fee = evPaymentsDue(v).where((p) => p.key == 'deposit').firstOrNull;
      return [
        Card(
          child: ListTile(
            leading: Icon(fee?.received == true ? Icons.check_circle : Icons.schedule),
            title: Text('Order fee ${evMoney(fee?.amount ?? 0, fee?.currency ?? 'RM')}'),
            subtitle: Text(fee?.received == true
                ? 'Received by TEKSI. Thank you.'
                : 'Due. TEKSI will contact you to collect it; your order goes ahead meanwhile.'),
          ),
        ),
        Text('Order placed · ${evOrderStatusLabel(v['status'])}'),
      ];
    }
    final fee = _fee(c);
    final total = evPriceBreakdown(_vehicle(c), _extras(c)).total;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Order fee', style: Theme.of(context).textTheme.labelLarge),
            Text(evMoney(fee.amount, fee.currency), style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            const Text('Non-refundable. It secures your vehicle and counts towards its price.'),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      const _Note(
        'Nothing is charged in the app. Placing the order records the fee as due, and TEKSI will contact you '
        'with how to pay it (bank transfer or at the showroom). You can carry on with the next steps meanwhile.',
      ),
      const SizedBox(height: 8),
      _Facts({'Vehicle total': evMoney(total), 'Order fee': evMoney(fee.amount, fee.currency)}),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _busy ? null : () => _placeOrder(c),
        icon: const Icon(Icons.check),
        label: const Text('Place order'),
      ),
    ];
  }

  Future<void> _placeOrder(EvCatalog c) async {
    final unit = _inventoryMode ? _unit(c) : null;
    final profile = ref.read(profileProvider).value;
    final values = newEvOrderValues(
      customerName: profile?.name ?? '',
      customerPhone: profile?.phone ?? '',
      vehicle: _vehicle(c),
      unit: unit,
      exteriorColour: unit?.exteriorColour ?? _exterior ?? '',
      interiorColour: unit?.interiorColour ?? _interior ?? '',
      wheels: _wheel,
      extras: _extras(c),
      fee: _fee(c),
    );
    setState(() => _busy = true);
    try {
      final id = await _repo.create(values);
      if (!mounted) return;
      setState(() {
        _orderId = id;
        _order = values;
        _step++;
      });
      _say('Order placed. The order fee is recorded as due.');
    } catch (e) {
      _say('Could not place the order: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- 4. Ownership ------------------------------------------------------------

  List<Widget> _ownershipStep() {
    final v = _order!;
    final confirmed = isEvOwnershipConfirmed(v);
    Widget field(String key, String label, {int lines = 1}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: _fields[key],
            maxLines: lines,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          ),
        );
    return [
      const Text('Who will the vehicle be registered to?'),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'self', label: Text('Myself')),
          ButtonSegment(value: 'other', label: Text('Someone else')),
          ButtonSegment(value: 'company', label: Text('Company')),
        ],
        selected: {_ownerType},
        onSelectionChanged: (s) => setState(() => _ownerType = s.first),
      ),
      const SizedBox(height: 12),
      if (_ownerType == 'company') ...[
        field('companyName', 'Company name'),
        field('companyRegNo', 'Registration number'),
        field('companyAddress', 'Company address', lines: 2),
        _section("Director's or authorised person's ID"),
      ],
      if (_ownerType == 'other') field('relationship', 'Relationship to you'),
      Row(children: [
        Expanded(
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'national', label: Text('National ID')),
              ButtonSegment(value: 'passport', label: Text('Passport')),
            ],
            selected: {_idType},
            onSelectionChanged: (s) => setState(() => _idType = s.first),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: evIdCountries.contains(_idCountry) ? _idCountry : 'Other',
        decoration: const InputDecoration(labelText: 'Country of issue', border: OutlineInputBorder()),
        items: [for (final c in evIdCountries) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (c) => setState(() => _idCountry = c ?? _idCountry),
      ),
      const SizedBox(height: 8),
      field('fullName', 'Full name (as on the ID)'),
      field('idNumber', _idType == 'passport' ? 'Passport number' : 'ID number'),
      field('address', 'Address', lines: 2),
      _idPhoto(v),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy ? null : _confirmOwnership,
        child: Text(confirmed ? 'Update owner details' : 'Confirm owner details'),
      ),
      if (confirmed) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Owner details saved.')),
    ];
  }

  Widget _idPhoto(Map<String, dynamic> v) {
    final url = '${v['ownerIdImage'] ?? ''}';
    return Card(
      child: ListTile(
        leading: url.isEmpty
            ? const Icon(Icons.badge_outlined)
            : ClipRRect(borderRadius: BorderRadius.circular(6), child: StoredImage(url, width: 56, height: 40)),
        title: Text(url.isEmpty ? 'Photo of the ID (optional)' : 'ID photo added'),
        subtitle: const Text('Helps TEKSI check the details. Only you and TEKSI can see your order.'),
        trailing: TextButton(onPressed: _busy ? null : _pickIdPhoto, child: Text(url.isEmpty ? 'Add' : 'Replace')),
      ),
    );
  }

  Future<void> _pickIdPhoto() async {
    final picked = await pickImage();
    final id = _orderId;
    if (picked == null || id == null) return;
    setState(() => _busy = true);
    try {
      final url = await _repo.uploadIdImage(id, picked.bytes, picked.ext == 'png' ? 'png' : 'jpg');
      await _save({'ownerIdImage': url, 'ownerPhoto': url}, done: 'ID photo added.');
    } catch (e) {
      _say('Could not upload the photo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmOwnership() async {
    final f = {for (final e in _fields.entries) e.key: e.value.text};
    final problem = ownershipProblem(f, _ownerType);
    if (problem != null) return _say(problem);
    await _save(ownershipPatch(f, _ownerType, _idType, _idCountry), done: 'Owner details saved.');
  }

  // ---- 5. Plate ---------------------------------------------------------------

  List<Widget> _plateStep() {
    final v = _order!;
    final choice = '${v['plateTransfer'] ?? ''}';
    return [
      const Text('Are you transferring a number plate you already own to this vehicle?'),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        emptySelectionAllowed: true,
        segments: const [
          ButtonSegment(value: 'yes', label: Text('Yes, transfer')),
          ButtonSegment(value: 'no', label: Text('No, issue new')),
        ],
        selected: {if (choice.isNotEmpty) choice},
        onSelectionChanged: (s) {
          if (s.isEmpty) return;
          _save({'plateTransfer': s.first, 'plateNumber': s.first == 'yes' ? _plate.text.trim() : ''});
        },
      ),
      const SizedBox(height: 12),
      if (choice == 'yes') ...[
        const _Note('The plate must be registered to the vehicle\'s new owner. JPJ completes the transfer.'),
        const SizedBox(height: 8),
        TextField(
          controller: _plate,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Plate number', hintText: 'WXY 1234', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  if (_plate.text.trim().isEmpty) return _say('Enter the plate number.');
                  _save({'plateNumber': _plate.text.trim().toUpperCase()}, done: 'Plate number saved.');
                },
          child: const Text('Save plate number'),
        ),
      ],
      if (choice == 'no') const Text('JPJ will issue a new plate number on delivery.'),
    ];
  }

  // ---- 6. Financing ------------------------------------------------------------

  List<Widget> _financingStep(EvCatalog c) {
    final v = _order!;
    final types = availableFinanceTypes([for (final o in c.financeOptions) o.values]);
    final type = mapAdminTypeToFinanceType(v['financeType']);
    final plans = type == null ? const <EvEntry>[] : financePlansFor(c.financeOptions, type);
    final total = toNumOrNull(v['total']) ?? 0;
    final fee = toNumOrNull(v['depositAmount']) ?? 0;
    final balance = outstandingBalance(total, fee);
    return [
      _Facts({'Vehicle total': evMoney(total), 'Order fee': evMoney(fee, '${v['depositCurrency'] ?? 'RM'}')}),
      const SizedBox(height: 12),
      if (types.isEmpty) const _Empty('No financing options are available yet. TEKSI will contact you.'),
      if (types.isNotEmpty) ...[
        _section('How will you pay?'),
        _chips([for (final t in types) evFinanceTypeLabels[t]!], evFinanceTypeLabels[type] ?? '', (label) {
          final t = evFinanceTypeLabels.entries.firstWhere((e) => e.value == label).key;
          if (t != type) _save(financeTypePatch(t));
        }),
      ],
      if (type != null) ...[
        _section('Plan'),
        if (plans.isEmpty) const _Empty('No plans of this kind are available.'),
        RadioGroup<String>(
          groupValue: '${v['financeChoice'] ?? ''}',
          onChanged: (id) {
            final p = plans.where((p) => p.id == id).firstOrNull;
            if (p != null && !_busy) _save({'financeChoice': p.id, 'financePlan': '${p.values['name'] ?? ''}'});
          },
          child: Column(children: [
            for (final p in plans)
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: p.id,
                title: Text('${p.values['name'] ?? 'Plan'}'),
                subtitle: Text([
                  if ('${p.values['details'] ?? ''}'.isNotEmpty) '${p.values['details']}',
                  describeFinancePlan(p.values),
                ].where((s) => s.isNotEmpty).join('\n')),
              ),
          ]),
        ),
      ],
      if (type == 'cash' && '${v['financeChoice'] ?? ''}'.isNotEmpty) ...[
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            title: Text('Balance to pay: ${evMoney(balance)}'),
            subtitle: Text(evFlag(v['cashBalancePaid'])
                ? 'Received by TEKSI.'
                : evFlag(v['cashBalanceConfirmed'])
                    ? 'Recorded as due. TEKSI will contact you with how to pay it.'
                    : 'The vehicle total less the order fee, paid to TEKSI before delivery.'),
            trailing: evFlag(v['cashBalanceConfirmed']) || evFlag(v['cashBalancePaid'])
                ? const Icon(Icons.check_circle)
                : FilledButton(
                    onPressed: _busy ? null : () => _save({'cashBalanceConfirmed': true, 'balanceDueAmount': balance}),
                    child: const Text('Confirm'),
                  ),
          ),
        ),
      ],
      if (type == 'leasing' && '${v['financeChoice'] ?? ''}'.isNotEmpty) ..._leasingAddon(v),
      if (type == 'hp' || type == 'rental')
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: _Note('Your delivery advisor will arrange the paperwork for this plan with you.'),
        ),
    ];
  }

  List<Widget> _leasingAddon(Map<String, dynamic> v) {
    final required = '${v['leasingAddonRequired'] ?? ''}';
    final settled = evFlag(v['leasingAddonConfirmed']) || evFlag(v['leasingAddonPaid']);
    return [
      _section('Does your lease need an add-on payment?'),
      SegmentedButton<String>(
        emptySelectionAllowed: true,
        segments: const [
          ButtonSegment(value: 'no', label: Text('No add-on')),
          ButtonSegment(value: 'yes', label: Text('Yes, add-on')),
        ],
        selected: {if (required.isNotEmpty) required},
        onSelectionChanged: (s) {
          if (s.isEmpty) return;
          _save({'leasingAddonRequired': s.first, 'leasingAddonConfirmed': false, 'leasingAddonPaid': false});
        },
      ),
      if (required == 'yes') ...[
        const SizedBox(height: 8),
        if (settled)
          ListTile(
            leading: const Icon(Icons.check_circle),
            title: Text('Add-on ${evMoney(toNumOrNull(v['leasingAddonAmount']) ?? 0)}'),
            subtitle: Text(evFlag(v['leasingAddonPaid']) ? 'Received by TEKSI.' : 'Recorded as due.'),
          )
        else
          Row(children: [
            Expanded(
              child: TextField(
                controller: _addon,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Add-on amount (RM)', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () {
                      final amount = double.tryParse(_addon.text.trim());
                      if (amount == null || amount <= 0) return _say('Enter the add-on amount.');
                      _save({'leasingAddonConfirmed': true, 'leasingAddonAmount': amount});
                    },
              child: const Text('Confirm'),
            ),
          ]),
      ],
    ];
  }

  // ---- 7. Advisor ---------------------------------------------------------------

  List<Widget> _advisorStep(EvCatalog c) {
    final v = _order!;
    if ('${v['advisorId'] ?? ''}'.isNotEmpty) {
      return [
        const Text('Your delivery advisor will guide you through to handover.'),
        const SizedBox(height: 8),
        _Facts({
          'Advisor': '${v['advisorName'] ?? ''}',
          'Dealership': '${v['advisorDealership'] ?? ''}',
          'DA number': '${v['advisorDaNumber'] ?? ''}',
          'Phone': '${v['advisorContact'] ?? ''}',
          'Email': '${v['advisorEmail'] ?? ''}',
          'Location': [v['advisorCity'], v['advisorState'], v['advisorCountry']]
              .where((s) => '${s ?? ''}'.isNotEmpty)
              .join(', '),
        }),
      ];
    }
    return [
      const _Note('Awaiting assignment. TEKSI will assign a delivery advisor to your order; check back here.'),
      const SizedBox(height: 16),
      _section('Already have a delivery advisor?'),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _daCode,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Their DA code', hintText: 'DA-0001', border: OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  final advisor = advisorByDaCode(c.advisors, _daCode.text);
                  if (advisor == null) return _say('No delivery advisor has that code.');
                  _save(advisorAssignmentPatch(advisor.id, advisor.values, DateTime.now()),
                      done: 'Linked to ${advisor.values['name'] ?? 'your advisor'}.');
                },
          child: const Text('Link'),
        ),
      ]),
    ];
  }

  // ---- 8. Schedule ---------------------------------------------------------------

  List<Widget> _scheduleStep() {
    final v = _order!;
    final chosen = '${v['deliveryDate'] ?? ''}';
    final ready = evOrderStatusAtLeast(v['status'], 'ready_for_delivery');
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return [
      _Note(ready ? 'Your vehicle is ready for delivery.' : 'Your vehicle is being prepared. Pick the day that suits you.'),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final d in deliverySlots(DateTime.now()))
          ChoiceChip(
            label: Text('${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}'),
            selected: isoDate(d) == chosen,
            onSelected: _busy ? null : (_) => _save({'deliveryDate': isoDate(d)}),
          ),
      ]),
      if (chosen.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text('Delivery booked for $chosen.')),
    ];
  }

  // ---- 9. Delivery -----------------------------------------------------------------

  List<Widget> _deliveryStep(EvCatalog c) {
    final v = _order!;
    final submitted = isChecklistSubmitted(v);
    final accepted = isChecklistAccepted(v);
    final items = buildChecklistDraft(c.checklist, v);
    final due = evPaymentsDue(v).where((p) => !p.received).toList();
    return [
      _Note(accepted
          ? 'Delivery accepted. Enjoy your TEKSI EV!'
          : submitted
              ? 'Your advisor has completed the handover checklist. Check it, then accept delivery.'
              : 'Your advisor will complete this checklist at handover.'),
      const SizedBox(height: 8),
      if (items.isEmpty) const _Empty('No delivery checklist has been set up yet.'),
      for (final i in items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(submitted && i.done ? Icons.check_circle : Icons.radio_button_unchecked),
          title: Text(i.name),
          subtitle: i.note.isEmpty ? null : Text(i.note),
        ),
      if (due.isNotEmpty) ...[
        const SizedBox(height: 8),
        _Note('Still to pay TEKSI: ${due.map((p) => '${p.label} ${evMoney(p.amount, p.currency)}').join(', ')}.'),
      ],
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy || accepted || !submitted
            ? null
            : () async {
                final ok = await _save({
                  'checklistAccepted': true,
                  'checklistAcceptedAt': DateTime.now().toUtc().toIso8601String(),
                  'status': 'delivered',
                }, done: 'Delivery accepted.');
                if (ok) await _repo.rememberActive(null);
              },
        child: Text(accepted ? 'Delivery accepted' : 'Accept delivery'),
      ),
    ];
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );
}

double? toNumOrNull(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.trim());

class _Facts extends StatelessWidget {
  const _Facts(this.facts);
  final Map<String, String> facts;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            for (final e in facts.entries)
              if (e.value.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 120, child: Text(e.key, style: Theme.of(context).textTheme.bodySmall)),
                    Expanded(child: Text(e.value)),
                  ]),
                ),
          ]),
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      );
}
