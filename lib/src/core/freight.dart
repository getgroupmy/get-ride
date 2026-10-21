/// Freight (migration 0267): a request for a van or lorry is a ride request
/// whose service is a Vehicle Service under the "Freight" Service type, with
/// the cargo on it. The sizes are the admin's own Vehicle Services (their
/// load and its size in the entry's values), the options are Ride Options
/// by place with a fixed charge each, and the fare is the rider's offer
/// plus those charges, bid on as any ride. Pure.
library;

import '../admin/screens/meterapp/display_logic.dart' show arrangeVehicles;
import 'fare.dart';
import 'fare_offer.dart';
import 'option_charge.dart';
import 'ride_option_charges.dart';
import 'ride_option_places.dart';
import 'partner_type_rules.dart' show RegionScope;
import 'ride_option_settings.dart';
import 'service_tree.dart';

/// The Service Settings type whose Vehicle Services are the freight sizes.
const freightServiceType = 'Freight';

/// Where the home Freight box goes when there is a size to book.
const freightPageRoute = '/freight';

/// The longest cargo description (as the server keeps it).
const cargoDescriptionMax = 500;

/// Whether a Vehicle Service's [types] (Service type names) make it freight.
bool isFreightTypes(Iterable<String> types) =>
    types.any((t) => t.trim().toLowerCase() == freightServiceType.toLowerCase());

/// Whether a Vehicle Services entry's [values] make it freight.
bool isFreightValues(Map<String, dynamic> values) =>
    values['serviceTypes'] is List && isFreightTypes([for (final t in values['serviceTypes'] as List) '$t']);

/// Whether [s] is booked from the Freight page rather than the ride bar.
bool isFreightService(RideService s) => isFreightTypes(s.serviceTypes);

/// A freight size: a Vehicle Service under Freight, with its load.
class FreightVehicle {
  const FreightVehicle({
    required this.id,
    required this.name,
    this.description = '',
    this.image,
    this.maxLoadKg,
    this.lengthM,
    this.widthM,
    this.heightM,
    this.closedBody = false,
    this.multiplier = 1,
    this.serviceTypes = const [freightServiceType],
    this.parentIds = const [],
  });

  /// The Vehicle Services entry; [name] is what lands in `ride_requests.service`.
  final String id;
  final String name;
  final String description;

  /// The catalogue's picture (hero image, else icon); null for the icon.
  final String? image;
  final double? maxLoadKg;
  final double? lengthM, widthM, heightM;

  /// A covered van or lorry (the "Closed body" option books only these).
  final bool closedBody;
  final double multiplier;
  final List<String> serviceTypes;
  final List<String> parentIds;

  /// As a ride service, for the fare tariff and the region rules.
  RideService get service =>
      RideService(name, description, multiplier, 1, id: id, image: image, serviceTypes: serviceTypes, parentIds: parentIds);

  /// "up to 500 kg", or null without a load.
  String? get loadText => maxLoadKg == null ? null : 'up to ${_groupedKg(maxLoadKg!)} kg';

  /// "len/wid/hgt 2.0/1.4/1.3 m", or null without any of them.
  String? get sizeText {
    if (lengthM == null && widthM == null && heightM == null) return null;
    String m(double? v) => v == null ? '-' : v.toStringAsFixed(1);
    return 'len/wid/hgt ${m(lengthM)}/${m(widthM)}/${m(heightM)} m';
  }

  /// "up to 500 kg · boxes, small appliances", the size's own line.
  String get subtitle => [?loadText, if (description.isNotEmpty) description].join(' · ');
}

String _groupedKg(double kg) {
  final whole = kg == kg.roundToDouble();
  final text = whole ? kg.round().toString() : kg.toStringAsFixed(1);
  if (!whole || text.length <= 3) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) out.write(',');
    out.write(text[i]);
  }
  return out.toString();
}

double? _num(Object? raw) {
  final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}'.trim());
  return v != null && v.isFinite && v > 0 ? v : null;
}

String? _image(Object? raw) {
  final s = '${raw ?? ''}'.trim();
  return s.isEmpty ? null : s;
}

/// The sizes a rider can book: the active Vehicle Services under Freight,
/// in display priority (the ride bar's hide list and order are the ride
/// bar's, not these).
List<FreightVehicle> freightVehiclesFrom(List<({String id, Map<String, dynamic> values})> entries) {
  final active = arrangeVehicles(entries, const {}, id: (e) => e.id, values: (e) => e.values);
  return [
    for (final e in active)
      if (isFreightValues(e.values))
        () {
          final v = e.values;
          final cost = _num(v['costPerKm']);
          final name = '${v['name'] ?? ''}'.trim();
          return FreightVehicle(
            id: e.id,
            name: name.isEmpty ? 'Freight' : name,
            description: '${v['shortDescription'] ?? ''}'.trim(),
            image: _image(v['heroImageUri']) ?? _image(v['iconUri']),
            maxLoadKg: _num(v['maxLoadKg']),
            lengthM: _num(v['loadLengthM']),
            widthM: _num(v['loadWidthM']),
            heightM: _num(v['loadHeightM']),
            closedBody: v['closedBody'] == true,
            multiplier: cost == null ? 1 : cost / 1.5,
            serviceTypes: [for (final t in v['serviceTypes'] as List) '$t'],
            parentIds: serviceParentIds(v),
          );
        }(),
  ];
}

/// The home Freight box opens the Freight page only with a size to book.
bool freightAvailable(List<FreightVehicle> vehicles) => vehicles.isNotEmpty;

/// The size booked as [service] (a name), if it is one.
FreightVehicle? freightVehicleNamed(List<FreightVehicle> vehicles, String? service) {
  final n = (service ?? '').trim().toLowerCase();
  if (n.isEmpty) return null;
  for (final v in vehicles) {
    if (v.name.toLowerCase() == n) return v;
  }
  return null;
}

// ---- Options ----------------------------------------------------------------------------------

/// What each freight option means, on the (i) sheet.
String freightOptionExplanation(RideOptionKind k) => switch (k) {
  RideOptionKind.helperOne => 'The driver loads and carries, up to 30 kg per item',
  RideOptionKind.helperTwo => 'The driver plus one helper, heavier items',
  RideOptionKind.closedBody => 'Only covered vans and lorries, for rain and dust',
  RideOptionKind.rideAlong => 'One seat for you to travel with the cargo',
  _ => '',
};

/// The options a rider at the pickup sees for [vehicleId]: shown by the
/// admin, offered there and not blocked for that size.
List<RideOptionKind> freightOptionsHere(RideOptionsConfig config, RideOptionsHere here, {String? vehicleId}) => [
  for (final k in config.freightShown)
    if (here.places.availableAt(here.place, k, serviceId: vehicleId)) k,
];

/// [picked] after turning [k] on or off: one helper choice at a time.
Set<RideOptionKind> toggleFreightOption(Set<RideOptionKind> picked, RideOptionKind k) {
  if (picked.contains(k)) return {...picked}..remove(k);
  return {
    ...picked.where(
      (p) => !(k == RideOptionKind.helperOne && p == RideOptionKind.helperTwo) &&
          !(k == RideOptionKind.helperTwo && p == RideOptionKind.helperOne),
    ),
    k,
  };
}

/// The charge lines [picked] add to the offer: each option's fixed charge
/// at the pickup, under its own id and the name the rider saw. A percentage
/// (never set from the admin page) counts on the offer.
List<OptionChargeLine> freightOptionCharges(
  Set<RideOptionKind> picked,
  RideOptionsHere here,
  RideOptionsConfig config, {
  double offer = 0,
}) => [
  for (final k in config.order)
    if (k.freight && picked.contains(k))
      if (here.freight(k).on(offer) case final amount when amount > 0)
        OptionChargeLine(kind: k.id, name: config.labelOf(k), amount: amount),
];

/// "RM 30", or "Free" for none.
String freightChargeText(OptionCharge c, String Function(double) money) => c.isZero ? 'Free' : c.describe(money);

/// The freight options a request was booked with, by its names.
List<RideOptionKind> freightOptionsOf(Map<String, String> optionNames) => [
  for (final k in RideOptionKind.freightKinds)
    if (optionNames.containsKey(k.id)) k,
];

// ---- The request ------------------------------------------------------------------------------

/// When the cargo is picked up.
enum FreightPickupTime {
  soon('10-20 min'),
  withinHour('Up to 1 hour'),
  scheduled('Schedule');

  const FreightPickupTime(this.label);
  final String label;
}

/// The suggested offer for a size's estimate [recommended]: from a tenth
/// below it to a fifth above, in whole amounts.
({double low, double high}) freightSuggestedRange(double recommended) =>
    (low: (recommended * 0.9).floorToDouble(), high: (recommended * 1.2).ceilToDouble());

/// "Suggested RM 120 to 180 for this trip and vehicle."
String freightSuggestionText(double recommended, String Function(double) money) {
  final r = freightSuggestedRange(recommended);
  return 'Suggested ${money(r.low)} to ${money(r.high)} for this trip and vehicle.';
}

/// Why [typed] can't be offered for an estimate of [recommended] (null
/// for none known): the keypad's band around the estimate, as a ride's.
String? freightOfferProblem(double? typed, double? recommended, String Function(double) money) {
  if (typed == null || typed <= 0) return 'Enter your fare';
  if (recommended == null || recommended <= 0) return null;
  return fareOfferProblem(typed, recommended, money);
}

/// What the Freight page has filled in.
class FreightDraft {
  const FreightDraft({
    this.pickup = false,
    this.drop = false,
    this.description = '',
    this.vehicle,
    this.offer,
    this.photoUploading = false,
    this.declaredValue,
    this.declaredCap = 500,
    this.prohibitedAck = false,
  });

  final bool pickup, drop;
  final String description;
  final FreightVehicle? vehicle;
  final double? offer;
  final bool photoUploading;

  /// The value of the items the sender declares, and the most allowed at
  /// the pickup.
  final double? declaredValue;
  final double declaredCap;

  /// The sender confirmed the cargo has none of the prohibited items.
  final bool prohibitedAck;
}

/// The first thing missing before the request can go out; null when ready.
String? freightDraftProblem(FreightDraft d) {
  if (!d.pickup) return 'Add the pickup location.';
  if (!d.drop) return 'Add the destination.';
  if (d.description.trim().isEmpty) return 'Describe your cargo.';
  if (d.vehicle == null) return 'Choose a vehicle size.';
  if (d.declaredValue == null || d.declaredValue! < 0) return 'Enter the value of your items.';
  if (d.declaredValue! > d.declaredCap) return 'The value of your items is over the limit here.';
  if (!d.prohibitedAck) return 'Confirm that your cargo has none of the prohibited items.';
  if (d.offer == null || d.offer! <= 0) return 'Offer your fare.';
  if (d.photoUploading) return 'Wait for the photo to finish uploading.';
  return null;
}

/// The note drivers on an older app read: the cargo, the options and when.
String freightNote({
  required String description,
  required List<String> options,
  FreightPickupTime time = FreightPickupTime.soon,
}) => [
  'Freight: ${description.trim()}',
  if (options.isNotEmpty) options.join(', '),
  if (time == FreightPickupTime.withinHour) 'Pickup within 1 hour',
].join(' · ');

/// The fare booked: the rider's offer plus what the options add.
double freightFare(double offer, List<OptionChargeLine> charges) => cents(offer + optionChargesTotal(charges));

/// The rider's offer on a booked request: its fare less the option charges.
double freightOfferOf(double fare, List<OptionChargeLine> charges) => cents(fare - optionChargesTotal(charges));

/// The columns a freight request adds to a ride request.
Map<String, Object> freightRequestColumns({
  required String description,
  String? photoPath,
  double? declaredValue,
  bool prohibitedAck = false,
  FreightRecipient? recipient,
}) => {
  'cargo_description': description.trim(),
  if (photoPath != null && photoPath.isNotEmpty) 'cargo_photo_path': photoPath,
  'declared_value': ?declaredValue,
  'prohibited_ack': prohibitedAck,
  if (recipient != null && recipient.phone.trim().isNotEmpty) ...{
    if (recipient.name.trim().isNotEmpty) 'recipient_name': recipient.name.trim(),
    'recipient_phone': recipient.phone.trim(),
  },
};

/// A request's status on My freight requests.
String freightStatusLabel(String status) => switch (status) {
  'open' => 'Looking for drivers',
  'accepted' => 'Driver on the way',
  'arrived' => 'Driver has arrived',
  'on_trip' => 'On the way to the destination',
  'completed' => 'Delivered',
  'cancelled' => 'Cancelled',
  'expired' => 'No driver found',
  _ => status,
};

/// The private bucket for cargo photos (migration 0267).
const rideCargoBucket = 'ride-cargo';

/// Where a cargo photo goes: the rider's own folder.
String rideCargoPhotoPath(String uid, String tag, String ext) =>
    '$uid/cargo-$tag.${ext.isEmpty ? 'jpg' : ext.toLowerCase()}';

/// How long a signed link to a cargo photo lasts.
const rideCargoLinkTtl = Duration(hours: 1);

// ---- Waiting, the cancel fee and the declared value cap, by place -------------------------------

/// The Freight values a place keeps among its Ride Options charges
/// (migration 0267), each inherited from the place above.
abstract final class FreightPlaceKey {
  static const waitFreeMin = 'freight-wait-free-min';
  static const waitPerMin = 'freight-wait-per-min';
  static const cancelArrived = 'freight-cancel-arrived';
  static const declaredCap = OptionChargeKey.freightDeclaredCap;

  static const all = [waitFreeMin, waitPerMin, cancelArrived, declaredCap];

  /// What holds with nothing set anywhere (as the server has it).
  static double fallback(String key) => switch (key) {
    waitFreeMin => 20,
    declaredCap => 500,
    _ => 0,
  };

  /// The most an admin may set (the server's check).
  static double max(String key) => key == declaredCap ? OptionChargeKey.freightDeclaredCapMax : (key == waitFreeMin ? 1440 : OptionCharge.maxAmount);
}

/// The Freight values at a pickup.
typedef FreightPlaceValues = ({double waitFreeMin, double waitPerMin, double cancelFee, double declaredCap});

FreightPlaceValues freightPlaceValues(OptionPlaces places, RegionScope place) {
  double v(String key) {
    final c = places.chargeAt(place, key);
    return c.from == null ? FreightPlaceKey.fallback(key) : c.value.charge.value;
  }

  return (
    waitFreeMin: v(FreightPlaceKey.waitFreeMin),
    waitPerMin: v(FreightPlaceKey.waitPerMin),
    cancelFee: v(FreightPlaceKey.cancelArrived),
    declaredCap: v(FreightPlaceKey.declaredCap),
  );
}

/// What waiting [waited] since the driver arrived costs at [v]: the whole
/// minutes past the free ones, times the fee a minute (as the server adds
/// it when the trip starts).
double freightWaitingFee(Duration waited, FreightPlaceValues v) {
  final minutes = waited.inMinutes;
  return cents(((minutes - v.waitFreeMin).clamp(0, double.infinity)) * v.waitPerMin);
}

/// "12:05" for the driver's waiting timer.
String freightTimerText(Duration d) {
  final s = d.isNegative ? Duration.zero : d;
  final m = s.inMinutes, sec = s.inSeconds % 60;
  return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

/// "20 min free, then RM1 a minute", or "20 min free" with no fee after.
String freightWaitingRule(FreightPlaceValues v, String Function(double) money) {
  final free = '${trimNumber(v.waitFreeMin)} min free';
  return v.waitPerMin > 0 ? '$free, then ${money(v.waitPerMin)} a minute' : free;
}

// ---- Settings ---------------------------------------------------------------------------------

/// Admin > Display Settings > Ride Options > Freight settings (app_settings
/// 'freight', migration 0267): how long a driver's cancel after pickup waits
/// for the sender, how the recipient gets the tracking link, and the
/// prohibited items.
class FreightConfig {
  const FreightConfig({
    this.cancelApproveMinutes = 5,
    this.recipientChannels = const {'sms'},
    this.prohibitedItems = defaultProhibitedItems,
  });

  static const defaultProhibitedItems = [
    'Explosives and fireworks',
    'Flammable liquids and gas cylinders',
    'Weapons and ammunition',
    'Illegal drugs',
    'Live animals',
    'Cash, jewellery and other valuables',
    'Hazardous chemicals',
  ];

  static const channels = ['sms', 'whatsapp'];

  final int cancelApproveMinutes;
  final Set<String> recipientChannels;
  final List<String> prohibitedItems;

  factory FreightConfig.fromJson(Object? raw) {
    if (raw is! Map) return const FreightConfig();
    final m = raw['cancelApproveMinutes'];
    final minutes = m is num ? m.round() : int.tryParse('${m ?? ''}');
    final ch = raw['recipientChannels'];
    final items = raw['prohibitedItems'];
    return FreightConfig(
      cancelApproveMinutes: (minutes ?? 5).clamp(1, 60),
      recipientChannels: ch is List ? {for (final c in ch) if (channels.contains('$c')) '$c'} : const {'sms'},
      prohibitedItems: items is List
          ? [for (final i in items) if ('$i'.trim().isNotEmpty) '$i'.trim()]
          : defaultProhibitedItems,
    );
  }

  Map<String, Object> toJson() => {
    'cancelApproveMinutes': cancelApproveMinutes,
    'recipientChannels': [for (final c in channels) if (recipientChannels.contains(c)) c],
    'prohibitedItems': prohibitedItems,
  };

  FreightConfig copyWith({int? cancelApproveMinutes, Set<String>? recipientChannels, List<String>? prohibitedItems}) =>
      FreightConfig(
        cancelApproveMinutes: cancelApproveMinutes ?? this.cancelApproveMinutes,
        recipientChannels: recipientChannels ?? this.recipientChannels,
        prohibitedItems: prohibitedItems ?? this.prohibitedItems,
      );
}

/// [items] with [item] added once (no case-only repeats); blank is ignored.
List<String> withProhibitedItem(List<String> items, String item) {
  final t = item.trim();
  if (t.isEmpty || t.length > 120 || items.any((i) => i.toLowerCase() == t.toLowerCase())) return items;
  return [...items, t];
}

// ---- The sender's declarations and the recipient ---------------------------------------------

/// Why [value] can't be declared under [cap]; null when it can.
String? declaredValueProblem(double? value, double cap, String Function(double) money) {
  if (value == null || value < 0) return 'Enter the value of your items.';
  if (value > cap) return 'The value of your items can be at most ${money(cap)} here.';
  return null;
}

/// A phone the recipient can be sent the link at: digits, spaces, ( ) -
/// and a leading +, 6 to 24 characters.
bool recipientPhoneOk(String phone) => RegExp(r'^\+?[0-9 ()-]{6,24}$').hasMatch(phone.trim());

/// The recipient as given: a name and a phone, or none.
typedef FreightRecipient = ({String name, String phone});

/// Where a proof of delivery goes: the driver's own folder (a photo) or the
/// sender's (the signature).
String freightProofPath(String uid, String kind, String tag, String ext) =>
    '$uid/$kind-$tag.${ext.isEmpty ? 'jpg' : ext.toLowerCase()}';
