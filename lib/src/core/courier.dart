/// Courier (migration 0268): a parcel sent by walker, bicycle, motorcycle
/// or car is a ride request whose service is a Vehicle Service under the
/// "Courier" Service type, built on Freight's parts (core/freight.dart):
/// the cargo, proof of delivery, waiting and cancel fees, prohibited items,
/// the declared value and the recipient's tracking link. On top: the parcel
/// size (S / M / L), who pays (the sender, or the recipient in cash on
/// delivery) and the confirmation code the courier enters at drop-off. Pure.
library;

import 'freight.dart';

/// Where the home Couriers box goes when there is a vehicle to book.
const courierPageRoute = '/courier';

/// The longest note about the parcel on the Courier page.
const courierNoteMax = 200;

/// The parcel sizes, with their kilos unless the Courier settings say
/// otherwise.
enum ParcelSize {
  s('S', 5),
  m('M', 15),
  l('L', 20);

  const ParcelSize(this.id, this.defaultKg);

  /// As kept in `ride_requests.parcel_size`.
  final String id;
  final double defaultKg;

  static ParcelSize? byId(Object? id) {
    for (final p in values) {
      if (p.id == '$id'.trim().toUpperCase()) return p;
    }
    return null;
  }
}

/// Who pays for the delivery.
enum CourierPayer {
  sender('sender', 'Me'),
  recipient('recipient', 'Recipient');

  const CourierPayer(this.id, this.label);
  final String id;
  final String label;

  static CourierPayer of(Object? id) => id == 'recipient' ? recipient : sender;
}

/// The quick items a sender adds with a tap.
const courierQuickItems = ['Food', 'Clothes', 'Documents', 'Electronics', 'Pharmacy'];

/// [picked] after a tap on [item].
List<String> toggleCourierItem(List<String> picked, String item) =>
    picked.contains(item) ? [for (final p in picked) if (p != item) p] : [...picked, item];

/// What is sent, as `cargo_description`: the items picked, then the note;
/// "Parcel" when neither says.
String courierItemText(List<String> items, String note) {
  final parts = [if (items.isNotEmpty) items.join(', '), if (note.trim().isNotEmpty) note.trim()];
  return parts.isEmpty ? 'Parcel' : parts.join('. ');
}

/// Admin > Display Settings > Ride Options > Courier settings
/// (app_settings 'courier', migration 0268).
class CourierConfig {
  const CourierConfig({
    this.codeChannels = const {'sms', 'sender'},
    this.cancelApproveMinutes = 5,
    this.parcelKg = const {},
    this.prohibitedItems = FreightConfig.defaultProhibitedItems,
  });

  /// Who gets the confirmation code: the recipient by 'sms' and / or
  /// 'whatsapp' (with the tracking link), and / or the 'sender' in the app.
  static const channels = ['sms', 'whatsapp', 'sender'];

  final Set<String> codeChannels;
  final int cancelApproveMinutes;

  /// The kilos per size the admin set; the defaults for the rest.
  final Map<ParcelSize, double> parcelKg;
  final List<String> prohibitedItems;

  double kgOf(ParcelSize p) => parcelKg[p] ?? p.defaultKg;

  /// The recipient gets messages (and the code) by these.
  Set<String> get messageChannels => {for (final c in codeChannels) if (c != 'sender') c};

  /// The sender sees the code in the app (also when it goes nowhere else).
  bool get senderSeesCode => codeChannels.contains('sender') || messageChannels.isEmpty;

  factory CourierConfig.fromJson(Object? raw) {
    if (raw is! Map) return const CourierConfig();
    final ch = raw['codeChannels'];
    final m = raw['cancelApproveMinutes'];
    final minutes = m is num ? m.round() : int.tryParse('${m ?? ''}');
    final sizes = raw['parcelSizes'];
    final items = raw['prohibitedItems'];
    final picked = ch is List ? {for (final c in ch) if (channels.contains('$c')) '$c'} : const {'sms', 'sender'};
    return CourierConfig(
      codeChannels: picked.isEmpty ? const {'sender'} : picked,
      cancelApproveMinutes: (minutes ?? 5).clamp(1, 60),
      parcelKg: {
        if (sizes is Map)
          for (final p in ParcelSize.values)
            if (sizes[p.id] case final num kg when kg >= 0.1 && kg <= 1000) p: kg.toDouble(),
      },
      prohibitedItems: items is List
          ? [for (final i in items) if ('$i'.trim().isNotEmpty) '$i'.trim()]
          : FreightConfig.defaultProhibitedItems,
    );
  }

  Map<String, Object> toJson() => {
    'codeChannels': [for (final c in channels) if (codeChannels.contains(c)) c],
    'cancelApproveMinutes': cancelApproveMinutes,
    'parcelSizes': {for (final p in ParcelSize.values) p.id: kgOf(p)},
    'prohibitedItems': prohibitedItems,
  };

  CourierConfig copyWith({
    Set<String>? codeChannels,
    int? cancelApproveMinutes,
    Map<ParcelSize, double>? parcelKg,
    List<String>? prohibitedItems,
  }) => CourierConfig(
    codeChannels: codeChannels ?? this.codeChannels,
    cancelApproveMinutes: cancelApproveMinutes ?? this.cancelApproveMinutes,
    parcelKg: parcelKg ?? this.parcelKg,
    prohibitedItems: prohibitedItems ?? this.prohibitedItems,
  );
}

/// A code channel as the admin reads it.
String courierChannelLabel(String c) => switch (c) {
  'sms' => 'SMS to the recipient',
  'whatsapp' => 'WhatsApp to the recipient',
  'sender' => 'Shown to the sender',
  _ => c,
};

/// "S · up to 5 kg".
String parcelSizeText(ParcelSize p, CourierConfig c) => '${p.id} · up to ${trimKg(c.kgOf(p))} kg';

String trimKg(double kg) => kg == kg.roundToDouble() ? kg.round().toString() : kg.toStringAsFixed(1);

/// Whether [v] can carry a parcel of [size]: no load set, or at least its kilos.
bool courierCarries(FreightVehicle v, ParcelSize size, CourierConfig c) =>
    v.maxLoadKg == null || v.maxLoadKg! >= c.kgOf(size);

/// The vehicles offered for a parcel of [size].
List<FreightVehicle> courierVehiclesFor(List<FreightVehicle> vehicles, ParcelSize size, CourierConfig c) => [
  for (final v in vehicles)
    if (courierCarries(v, size, c)) v,
];

/// The home Couriers box opens the Courier page only with a vehicle to book.
bool courierAvailable(List<FreightVehicle> vehicles) => vehicles.isNotEmpty;

/// What the Courier page has filled in.
class CourierDraft {
  const CourierDraft({
    this.pickup = false,
    this.drop = false,
    this.size,
    this.vehicle,
    this.recipientPhone = '',
    this.declaredValue,
    this.declaredCap = 500,
    this.prohibitedAck = false,
    this.offer,
  });

  final bool pickup, drop;
  final ParcelSize? size;
  final FreightVehicle? vehicle;
  final String recipientPhone;
  final double? declaredValue;
  final double declaredCap;
  final bool prohibitedAck;
  final double? offer;
}

/// The first thing missing before the request can go out; null when ready.
String? courierDraftProblem(CourierDraft d, CourierConfig c) {
  if (!d.pickup) return 'Add where to pick up.';
  if (!d.drop) return 'Add where to deliver.';
  if (d.recipientPhone.trim().isEmpty) return "Add the recipient's phone number.";
  if (!recipientPhoneOk(d.recipientPhone)) return 'Enter a phone number, such as +60 12 345 6789.';
  if (d.size == null) return 'Choose the parcel size.';
  if (d.vehicle == null) return 'Choose a vehicle.';
  if (!courierCarries(d.vehicle!, d.size!, c)) return 'This parcel is too heavy for a ${d.vehicle!.shortName}.';
  if (d.declaredValue == null || d.declaredValue! < 0) return 'Enter the value of your items.';
  if (d.declaredValue! > d.declaredCap) return 'The value of your items is over the limit here.';
  if (!d.prohibitedAck) return 'Confirm that your parcel has none of the prohibited items.';
  if (d.offer == null || d.offer! <= 0) return 'Offer your price.';
  return null;
}

/// The columns a courier request adds to a freight one.
Map<String, Object> courierRequestColumns({required ParcelSize size, CourierPayer payer = CourierPayer.sender}) => {
  'parcel_size': size.id,
  'payer': payer.id,
};

/// The note drivers on an older app read.
String courierNote({required String items, required ParcelSize size, CourierPayer payer = CourierPayer.sender}) => [
  'Courier: ${items.trim()}',
  'Size ${size.id}',
  if (payer == CourierPayer.recipient) 'Recipient pays cash',
].join(' · ');

/// A delivery's status on My deliveries.
String courierStatusLabel(String status) => switch (status) {
  'open' => 'Looking for couriers',
  'accepted' => 'Courier on the way',
  'arrived' => 'Courier at the pickup',
  'on_trip' => 'On the way to the recipient',
  'completed' => 'Delivered',
  'cancelled' => 'Cancelled',
  'expired' => 'No courier found',
  _ => status,
};

/// A status label of [kind].
String deliveryStatusLabel(DeliveryKind kind, String status) =>
    kind == DeliveryKind.courier ? courierStatusLabel(status) : freightStatusLabel(status);

/// What courier_code_check answered, for the courier; null when it passed.
String? courierCodeMessage(String outcome) {
  if (outcome == 'ok') return null;
  if (outcome == 'wrong_code') return "That code isn't right. Ask the recipient again.";
  if (outcome.startsWith('rate_limited:')) {
    final s = int.tryParse(outcome.substring('rate_limited:'.length)) ?? 60;
    final min = (s / 60).ceil();
    return 'Too many tries. Try again in $min min.';
  }
  return "Couldn't check the code. Try again.";
}

/// Whether [code] is four digits.
bool courierCodeOk(String code) => RegExp(r'^[0-9]{4}$').hasMatch(code.trim());

/// What the sender reads about the code, by the admin's channels.
String courierCodeHelp(CourierConfig c) {
  final sent = [
    if (c.messageChannels.contains('sms')) 'SMS',
    if (c.messageChannels.contains('whatsapp')) 'WhatsApp',
  ];
  if (sent.isEmpty) return 'Give this code to the recipient. The courier enters it to finish the delivery.';
  final how = sent.join(' and ');
  return c.codeChannels.contains('sender')
      ? 'We also send it to the recipient by $how. The courier enters it to finish the delivery.'
      : 'We send it to the recipient by $how. The courier enters it to finish the delivery.';
}

/// "Recipient pays RM 10.00 in cash on delivery."
String recipientPaysText(String amount) => 'Recipient pays $amount in cash on delivery.';

/// For the courier: "Collect RM 10.00 in cash from the recipient."
String collectFromRecipientText(String amount) => 'Collect $amount in cash from the recipient.';
