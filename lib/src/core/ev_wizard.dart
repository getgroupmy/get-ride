// The TEKSI EV car-buying wizard, the pure half: ported from the Expo app's
// `app/teksi-ev.tsx` (the order logic it shares with the back office lives in
// `admin/screens/commerce/ev_orders.dart`).
//
// Two deliberate departures from Expo:
//
// * Nothing is "paid" in the app. Expo showed a card / FPX form that charged
//   nothing and then recorded the order fee, a cash balance and a leasing
//   add-on as paid. Here the customer confirms what is owed, the order records
//   it as due, and the back office marks each sum received once it has been
//   collected.
// * The ID card is never sent to a third-party AI to be read; the customer
//   types the details.

import '../admin/screens/commerce/commerce_logic.dart';
import '../admin/screens/commerce/ev_orders.dart';

String _s(Object? v) => v == null ? '' : '$v'.trim();

/// The wizard's steps, in order (the keys `deriveEvOrderStep` answers in).
const evStepTitles = {
  'model': 'Choose model',
  'specification': 'Specification',
  'deposit': 'Order fee',
  'ownership': 'Ownership',
  'plate': 'Licence plate',
  'financing': 'Financing',
  'advisor': 'Delivery advisor',
  'schedule': 'Schedule delivery',
  'delivery': 'Delivery checklist',
};

/// Wheel options every custom build offers; the middle one is the default.
const evWheelOptions = ['18" Standard', '19" Aero', '20" Performance'];
const evDefaultWheel = '19" Aero';

/// Where an ID can be issued (Expo `ID_COUNTRIES`).
const evIdCountries = [
  'Malaysia', 'Singapore', 'Indonesia', 'Thailand', 'Philippines', 'Vietnam', //
  'China', 'India', 'United Kingdom', 'United States', 'Australia', 'Other',
];

/// A named, priced option of a vehicle (a feature or an accessory).
typedef EvPricedItem = ({String id, String name, double price});

/// One enabled colour of a vehicle.
typedef EvColour = ({String id, String name, String code});

List<EvPricedItem> _priced(Object? raw) => [
      for (final c in parseItemList(raw))
        if (c['enabled'] != false && _s(c['name']).isNotEmpty) (id: _s(c['id']), name: _s(c['name']), price: toNum(c['price'])),
    ];

List<EvColour> _colours(Object? raw, Object? legacyCsv, String fallbackCsv) {
  final list = [
    for (final c in parseItemList(raw))
      if (c['enabled'] != false && _s(c['name']).isNotEmpty) (id: _s(c['id']), name: _s(c['name']), code: _s(c['code'])),
  ];
  if (list.isNotEmpty) return list;
  final csv = _s(legacyCsv).isEmpty ? fallbackCsv : _s(legacyCsv);
  return [
    for (final n in csv.split(','))
      if (n.trim().isNotEmpty) (id: n.trim(), name: n.trim(), code: ''),
  ];
}

/// A model from `ev_vehicle_details`, as the wizard shows it.
class EvVehicle {
  EvVehicle(this.id, Map<String, dynamic> v)
      : make = _s(v['make']),
        model = _s(v['model']),
        country = _s(v['country']),
        imageUri = _s(v['imageUri']),
        price = toNum(v['price']),
        tax = _taxOf(v),
        exteriorColours = _colours(v['exteriorColors'], v['exteriorColor'], 'Pearl White,Solid Black,Midnight Blue,Red'),
        interiorColours = _colours(v['interiorColors'], v['interiorColor'], 'Black,White,Cream'),
        features = _priced(v['features']),
        accessories = _accessories(v),
        gallery = [
          for (final (key, label) in const [
            ('exteriorImages', 'Exterior'),
            ('interiorImages', 'Interior'),
            ('storageImages', 'Storage'),
          ])
            for (final u in parseStringList(v[key]))
              if (u.isNotEmpty) (url: u, label: label),
        ];

  final String id;
  final String make;
  final String model;
  final String country;
  final String imageUri;
  final double price;

  /// The enabled tax lines added up (or the legacy single `tax` figure).
  /// Expo read only `tax`, so a model with itemised taxes showed none.
  final double tax;
  final List<EvColour> exteriorColours;
  final List<EvColour> interiorColours;
  final List<EvPricedItem> features;
  final List<EvPricedItem> accessories;
  final List<({String url, String label})> gallery;

  String get name => '$make $model'.trim().isEmpty ? 'TEKSI EV' : '$make $model'.trim();

  static double _taxOf(Map<String, dynamic> v) {
    final lines = parseItemList(v['taxes']).where((t) => t['enabled'] != false);
    if (lines.isNotEmpty) return lines.fold(0, (sum, t) => sum + toNum(t['amount']));
    return toNum(v['tax']);
  }

  static List<EvPricedItem> _accessories(Map<String, dynamic> v) {
    final listed = _priced(v['accessories']);
    if (listed.isNotEmpty || parseItemList(v['accessories']).isNotEmpty) return listed;
    // The legacy "Name:cost" CSV, else Expo's stock set.
    final csv = _s(v['accessory']).isEmpty ? 'Roof Rack:300,Floor Mats:120,Tow Hitch:850,Tinted Windows:450' : _s(v['accessory']);
    return [
      for (final part in csv.split(','))
        if (part.split(':').first.trim().isNotEmpty)
          (id: part.split(':').first.trim(), name: part.split(':').first.trim(), price: toNum(part.split(':').skip(1).firstOrNull)),
    ];
  }
}

/// A ready unit from `ev_vehicle_inventory`, linked to its model.
class EvInventoryUnit {
  EvInventoryUnit(this.id, Map<String, dynamic> v, Map<String, EvVehicle> vehicles)
      : vehicle = vehicles[_s(v['vehicleId'])],
        vehicleId = _s(v['vehicleId']),
        vin = _s(v['vin']),
        country = _s(v['country']),
        exteriorColour = _s(v['exteriorColor']),
        interiorColour = _s(v['interiorColor']),
        factoryWheels = _s(v['wheels']).isEmpty ? evDefaultWheel : _s(v['wheels']),
        _make = _s(v['make']),
        _model = _s(v['model']),
        _featureIds = parseIdList(v['featureIds']),
        _accessoryIds = parseIdList(v['accessoryIds']);

  final String id;
  final EvVehicle? vehicle;
  final String vehicleId;
  final String vin;
  final String country;
  final String exteriorColour;
  final String interiorColour;
  final String factoryWheels;
  final String _make;
  final String _model;
  final List<String> _featureIds;
  final List<String> _accessoryIds;

  String get name {
    final v = vehicle;
    if (v != null && '${v.make}${v.model}'.isNotEmpty) return v.name;
    return '$_make $_model'.trim().isEmpty ? 'TEKSI EV' : '$_make $_model'.trim();
  }

  /// What the unit was built with, priced from its model.
  List<EvPricedItem> get includedFeatures => [...?vehicle?.features.where((f) => _featureIds.contains(f.id))];
  List<EvPricedItem> get includedAccessories => [...?vehicle?.accessories.where((a) => _accessoryIds.contains(a.id))];
}

/// A delivery advisor from `ev_delivery_advisors`.
typedef EvAdvisor = ({String id, Map<String, dynamic> values});

/// Finds the advisor whose DA number the customer typed (case and spacing
/// ignored).
EvAdvisor? advisorByDaCode(List<EvAdvisor> advisors, String code) {
  final c = code.trim().toLowerCase();
  if (c.isEmpty) return null;
  return advisors.where((a) => _s(a.values['daNumber']).toLowerCase() == c).firstOrNull;
}

/// The order fee for a country (Expo `resolveOrderFee`): the active fee for
/// that country, else the default one, else Malaysia's, else RM 3,000. An
/// explicit fee of 0 is honoured (Expo turned it into 3,000).
({double amount, String currency, String country}) resolveOrderFee(List<Map<String, dynamic>> fees, String? country) {
  final active = fees.where((v) => v['active'] != false).toList();
  final want = (country ?? '').trim().toLowerCase();
  final pick = active.where((v) => want.isNotEmpty && _s(v['country']).toLowerCase() == want).firstOrNull ??
      active.where((v) => v['isDefault'] == true).firstOrNull ??
      active.where((v) => _s(v['country']).toLowerCase() == defaultOrderFeeCountry.toLowerCase()).firstOrNull;
  if (pick == null) {
    return (amount: defaultOrderFeeAmount.toDouble(), currency: defaultOrderFeeCurrency, country: defaultOrderFeeCountry);
  }
  final amount = double.tryParse(_s(pick['amount']));
  return (
    amount: amount == null || !amount.isFinite || amount < 0 ? defaultOrderFeeAmount.toDouble() : amount,
    currency: _s(pick['currency']).isEmpty ? defaultOrderFeeCurrency : _s(pick['currency']),
    country: _s(pick['country']).isEmpty ? defaultOrderFeeCountry : _s(pick['country']),
  );
}

/// "RM 75,000" / "RM 1,234.50".
String evMoney(num amount, [String currency = 'RM']) {
  final cents = (amount * 100).round();
  final whole = cents ~/ 100, rest = (cents % 100).abs();
  return '$currency ${groupedNumber(whole)}${rest == 0 ? '' : '.${rest.toString().padLeft(2, '0')}'}';
}

/// Base price, tax and the options picked, added up.
({double base, double tax, double extras, double total}) evPriceBreakdown(EvVehicle? vehicle, Iterable<EvPricedItem> extras) {
  final base = vehicle?.price ?? 0, tax = vehicle?.tax ?? 0;
  final extra = extras.fold<double>(0, (sum, e) => sum + e.price);
  return (base: base, tax: tax, extras: extra, total: base + tax + extra);
}

/// The finance types offered (cash, hp, leasing, rental), from the active
/// options.
List<String> availableFinanceTypes(List<Map<String, dynamic>> options) {
  final types = {for (final o in options) if (o['active'] != false) mapAdminTypeToFinanceType(o['type'])};
  return [for (final t in const ['cash', 'hp', 'leasing', 'rental']) if (types.contains(t)) t];
}

const evFinanceTypeLabels = {'cash': 'Cash', 'hp': 'Hire Purchase', 'leasing': 'Leasing', 'rental': 'Rental'};

/// The active plans of [type], in the admin's display order.
List<({String id, Map<String, dynamic> values})> financePlansFor(
  List<({String id, Map<String, dynamic> values})> options,
  String type,
) {
  final plans = [
    for (final o in options)
      if (o.values['active'] != false && mapAdminTypeToFinanceType(o.values['type']) == type) o,
  ];
  plans.sort((a, b) => toNum(a.values['displayPriority']).compareTo(toNum(b.values['displayPriority'])));
  return plans;
}

/// "RM 1,200 · 2.85% · 60 Months".
String describeFinancePlan(Map<String, dynamic> v) {
  final parts = <String>[];
  if (_s(v['paymentMode']) == 'Full Balance') {
    parts.add('Full balance');
  } else if (toNum(v['paymentAmount']) > 0) {
    parts.add(evMoney(toNum(v['paymentAmount'])));
  }
  if (toNum(v['rate']) > 0) parts.add('${_s(v['rate'])}%');
  final term = toNum(v['termValue']);
  if (term > 0 && _s(v['termUnit']).isNotEmpty) {
    parts.add('${_s(v['termValue'])} ${_s(v['termUnit'])}${term > 1 ? 's' : ''}');
  }
  return parts.join(' · ');
}

/// What changing the finance type writes: the type, with everything that
/// belonged to the previous one cleared. (Expo left the old plan in place,
/// which could make an unfinished order look complete.)
Map<String, dynamic> financeTypePatch(String type) => {
      'financeType': type,
      'financeChoice': '',
      'financePlan': '',
      'cashBalancePaid': false,
      'cashBalanceConfirmed': false,
      'leasingAddonRequired': '',
      'leasingAddonPaid': false,
      'leasingAddonConfirmed': false,
      'leasingAddonAmount': '',
    };

/// The cash still owed once the order fee is counted.
double outstandingBalance(num total, num orderFee) => total - orderFee > 0 ? (total - orderFee).toDouble() : 0;

/// The dates a delivery can be booked on: three to seventeen days from
/// [now], in the phone's own calendar (Expo used UTC, which put the dates a
/// day out around midnight).
List<DateTime> deliverySlots(DateTime now) => [
      for (var i = 3; i < 18; i++) DateTime(now.year, now.month, now.day + i),
    ];

String isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The record a new order starts as, when the customer confirms the order
/// fee. The fee is recorded as due: nothing has been charged.
Map<String, dynamic> newEvOrderValues({
  required String customerName,
  required String customerPhone,
  required EvVehicle? vehicle,
  EvInventoryUnit? unit,
  required String exteriorColour,
  required String interiorColour,
  required String wheels,
  required List<EvPricedItem> extras,
  required ({double amount, String currency, String country}) fee,
}) {
  final price = evPriceBreakdown(vehicle, extras);
  final swapped = unit != null && wheels != unit.factoryWheels;
  return {
    'customerName': customerName.trim().isEmpty ? 'TEKSI Customer' : customerName.trim(),
    'customerPhone': customerPhone,
    'customerEmail': '',
    'mode': unit == null ? 'custom' : 'inventory',
    'vehicle': unit?.name ?? vehicle?.name ?? 'TEKSI EV',
    'inventoryId': unit?.id ?? '',
    'vehicleId': unit?.vehicleId ?? vehicle?.id ?? '',
    'exteriorColor': exteriorColour,
    'interiorColor': interiorColour,
    'wheels': wheels,
    'factoryWheels': unit?.factoryWheels ?? '',
    'wheelsSwapped': swapped,
    'refitRequired': swapped,
    'buildFlags': swapped ? 'Re-fit wheels' : '',
    'accessories': extras.map((e) => e.name).join(', '),
    'vin': unit?.vin ?? '',
    'basePrice': price.base,
    'tax': price.tax,
    'accessoriesCost': price.extras,
    'total': price.total,
    'depositPaid': false,
    'depositStatus': 'due',
    'depositAmount': fee.amount,
    'depositCurrency': fee.currency,
    'paymentMethod': '',
    'status': 'pending',
  };
}

/// The order to resume (Expo's adoption): the newest one that is neither
/// finished nor cancelled.
String? resumableEvOrder(List<({String id, Map<String, dynamic> values, DateTime createdAt})> orders) {
  final open = orders.where((o) {
    final s = normalizeEvOrderStatus(o.values['status']);
    return s != 'delivered' && s != 'cancelled' && !isChecklistAccepted(o.values);
  }).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return open.firstOrNull?.id;
}

/// The ownership fields, checked (Expo `confirmOwnership`). Null when they
/// are complete, else what is missing.
String? ownershipProblem(Map<String, String> f, String ownerType) {
  final missing = <String>[
    if ((f['fullName'] ?? '').trim().isEmpty) 'full name',
    if ((f['idNumber'] ?? '').trim().isEmpty) 'ID number',
    if ((f['address'] ?? '').trim().isEmpty) 'address',
    if (ownerType == 'other' && (f['relationship'] ?? '').trim().isEmpty) 'relationship',
    if (ownerType == 'company' && (f['companyName'] ?? '').trim().isEmpty) 'company name',
    if (ownerType == 'company' && (f['companyRegNo'] ?? '').trim().isEmpty) 'registration number',
    if (ownerType == 'company' && (f['companyAddress'] ?? '').trim().isEmpty) 'company address',
  ];
  return missing.isEmpty ? null : 'Please fill in the ${missing.join(', ')}.';
}

/// What confirming ownership writes onto the order.
Map<String, dynamic> ownershipPatch(Map<String, String> f, String ownerType, String idType, String idCountry) => {
      'ownerType': ownerType,
      'ownerIdType': ownerType == 'company' ? 'company+$idType' : idType,
      'ownerIdCountry': idCountry,
      'ownerFullName': (f['fullName'] ?? '').trim(),
      'ownerIdNumber': (f['idNumber'] ?? '').trim(),
      'ownerAddress': (f['address'] ?? '').trim(),
      'ownerRelationship': ownerType == 'other' ? (f['relationship'] ?? '').trim() : '',
      'companyName': ownerType == 'company' ? (f['companyName'] ?? '').trim() : '',
      'companyRegNo': ownerType == 'company' ? (f['companyRegNo'] ?? '').trim() : '',
      'companyAddress': ownerType == 'company' ? (f['companyAddress'] ?? '').trim() : '',
    };

/// Sums still owed on an order, for the customer and the back office: the
/// order fee, a cash balance and a leasing add-on, each with whether TEKSI
/// has recorded it received.
List<({String key, String label, double amount, String currency, bool received})> evPaymentsDue(Map<String, dynamic> v) {
  final currency = _s(v['depositCurrency']).isEmpty ? defaultOrderFeeCurrency : _s(v['depositCurrency']);
  final type = mapAdminTypeToFinanceType(v['financeType']);
  return [
    if (v.containsKey('depositAmount'))
      (key: 'deposit', label: 'Order fee', amount: toNum(v['depositAmount']), currency: currency, received: evFlag(v['depositPaid'])),
    if (type == 'cash' && (evFlag(v['cashBalanceConfirmed']) || evFlag(v['cashBalancePaid'])))
      (key: 'balance', label: 'Cash balance', amount: toNum(v['balanceDueAmount'] ?? v['balancePaidAmount']), currency: 'RM', received: evFlag(v['cashBalancePaid'])),
    if (type == 'leasing' && _s(v['leasingAddonRequired']) == 'yes' &&
        (evFlag(v['leasingAddonConfirmed']) || evFlag(v['leasingAddonPaid'])))
      (key: 'addon', label: 'Leasing add-on', amount: toNum(v['leasingAddonAmount']), currency: 'RM', received: evFlag(v['leasingAddonPaid'])),
  ];
}

/// What the back office writes when it records a sum received.
Map<String, dynamic> paymentReceivedPatch(String key, Map<String, dynamic> v, DateTime now) => switch (key) {
      'deposit' => {'depositPaid': true, 'depositStatus': 'received', 'depositReceivedAt': now.toIso8601String()},
      'balance' => {
          'cashBalancePaid': true,
          'balancePaidAmount': toNum(v['balanceDueAmount'] ?? v['balancePaidAmount']),
          'balanceReceivedAt': now.toIso8601String(),
        },
      'addon' => {'leasingAddonPaid': true, 'leasingAddonReceivedAt': now.toIso8601String()},
      _ => const {},
    };
