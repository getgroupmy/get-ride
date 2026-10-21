/// Plain models over the shared Supabase tables. Column names match the live
/// `public` schema of the get.ride project exactly.
library;

import '../core/format.dart';
import '../core/my_ride.dart';
import '../core/permits.dart' show PlateColours, plateColoursFromJson;
import '../core/promo_codes.dart';
import '../core/region_pricing.dart';
import '../core/ride_payment.dart';
import '../core/ride_assistance.dart';
import '../core/ride_option_charges.dart';
import '../core/ride_option_settings.dart' show RideOptionKind, bookedOptionName;
import '../core/ride_extras.dart';
import '../core/ride_pets.dart';
import '../core/ride_stops.dart';
import 'geo_service.dart';

double? _d(Object? v) => v == null ? null : (v as num).toDouble();
String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
int? _i(Object? v) => v == null ? null : (v as num).toInt();
DateTime? _t(Object? v) => v == null ? null : DateTime.tryParse(v as String);

enum RideStatus {
  open,
  accepted,
  arrived,
  onTrip,
  completed,
  cancelled,
  expired;

  /// Value stored in `ride_requests.status`.
  String get db => this == onTrip ? 'on_trip' : name;

  static RideStatus parse(String? s) => switch (s) {
        'accepted' => accepted,
        'arrived' => arrived,
        'on_trip' => onTrip,
        'completed' => completed,
        'cancelled' => cancelled,
        'expired' => expired,
        _ => open,
      };

  bool get isOngoing => this == open || this == accepted || this == arrived || this == onTrip;
  bool get isFinished => !isOngoing;

  String get label => switch (this) {
        open => 'Finding a driver',
        accepted => 'Driver on the way',
        arrived => 'Driver has arrived',
        onTrip => 'On trip',
        completed => 'Completed',
        cancelled => 'Cancelled',
        expired => 'No driver found',
      };
}

/// Rider statuses considered "in progress" (Expo `ONGOING_STATUSES`).
const riderOngoingStatuses = ['open', 'accepted', 'arrived', 'on_trip'];

/// Partner statuses considered "in progress" (Expo `PARTNER_ONGOING_STATUSES`).
const partnerOngoingStatuses = ['accepted', 'arrived', 'on_trip'];

class RideRequest {
  RideRequest(this.raw, {this.cachedAt});
  final Map<String, dynamic> raw;

  /// Set when this is the copy kept on the phone (no connection): when it
  /// was last seen on the server.
  final DateTime? cachedAt;
  bool get fromCache => cachedAt != null;

  String get id => raw['id'] as String;
  String? get riderId => raw['rider_id'] as String?;
  String? get riderName => raw['rider_name'] as String?;
  String? get riderPhone => raw['rider_phone'] as String?;

  /// Who the ride was booked for, when the rider booked it for someone else
  /// (migration 0107); null on the rider's own rides.
  String? get bookedForName => _text(raw['booked_for_name']);
  String? get bookedForPhone => _text(raw['booked_for_phone']);
  /// While a request is open the passenger's details are kept from drivers
  /// (migration 0195): only `booked_for_other` says it's for someone else.
  bool get isForOthers => bookedForPhone != null || raw['booked_for_other'] == true;

  /// The person who will be in the car, and their number.
  String get passengerName => bookedForName ?? riderName ?? 'Passenger';
  String? get passengerPhone => bookedForPhone ?? riderPhone;

  /// What a driver deciding on an open request sees: the rider's first name.
  String get firstNameForDrivers {
    final first = (riderName ?? '').trim().split(RegExp(r'\s+')).first;
    return first.isEmpty ? 'Passenger' : first;
  }

  /// A driver has the ride: the rider accepted them (or their offer) and the
  /// row moved past `open`. A bid on an open request also puts the bidder's
  /// details on the row, but that driver is not the rider's until accepted,
  /// so nothing of theirs (contact, trip code, SOS) is shown on it.
  bool get hasDriver =>
      raw['partner_id'] != null &&
      (status == RideStatus.accepted || status == RideStatus.arrived || status == RideStatus.onTrip);
  String? get service => raw['service'] as String?;
  String get paymentMode => (raw['payment_mode'] as String?) ?? 'Cash';
  String? get pickupName => raw['pickup_name'] as String?;
  String? get pickupAddress => raw['pickup_address'] as String?;
  double? get pickupLat => _d(raw['pickup_lat']);
  double? get pickupLng => _d(raw['pickup_lng']);
  String? get dropName => raw['drop_name'] as String?;
  String? get dropAddress => raw['drop_address'] as String?;
  double? get dropLat => _d(raw['drop_lat']);
  double? get dropLng => _d(raw['drop_lng']);
  double? get distanceKm => _d(raw['distance_km']);
  int? get durationMin => _i(raw['duration_min']);
  double? get fare => _d(raw['fare']);
  double? get offeredFare => _d(raw['offered_fare']);
  bool get offerMe => raw['offer_me'] == true;
  String get currency => (raw['currency'] as String?) ?? 'MYR';

  /// The pickup region's time zone at booking (IANA, migration 0124): the
  /// ride's times are shown as the clocks there showed them. Null on rides
  /// booked before it, or where the region has none — the phone's time then.
  String? get timezone {
    final z = raw['timezone'];
    return z is String && z.trim().isNotEmpty ? z.trim() : null;
  }
  int get passengers => _i(raw['passengers']) ?? 1;
  int? get luggage => _i(raw['luggage']);
  double? get riderRating => _d(raw['rider_rating']);

  /// How many ratings [riderRating] is the average of, and the rider's
  /// completed trips, stamped by the server at booking (migration 0269);
  /// null on rides from before it.
  int? get riderRatingsCount => _i(raw['rider_ratings_count']);
  int? get riderTrips => _i(raw['rider_trips']);

  /// A late-cancel or no-show fee from an earlier ride the rider's wallet
  /// couldn't pay, added to this one (0269); null when none.
  double? get priorFees => _d(raw['prior_fees']);

  /// What cancelling this ride cost the rider, and whether it was taken
  /// ('charged'), left 'due' for the next ride, or 'none' (0269).
  double? get cancelFee => _d(raw['cancel_fee']);
  String? get cancelFeeStatus => raw['cancel_fee_status'] as String?;

  /// The scheduled booking this ride was released from (0189); null for a ride now.
  String? get scheduledRideId => raw['scheduled_ride_id'] as String?;
  String? get note => raw['note'] as String?;
  RideStatus get status => RideStatus.parse(raw['status'] as String?);
  String? get partnerId => raw['partner_id'] as String?;
  String? get partnerName => raw['partner_name'] as String?;
  String? get partnerPhone => raw['partner_phone'] as String?;
  String? get partnerVehicle => raw['partner_vehicle'] as String?;
  String? get partnerPlate => raw['partner_plate'] as String?;

  /// The vehicle the driver had taken when they bid on or took the ride,
  /// its energy, partner types and plate colours (server-stamped, 0254).
  String? get partnerVehicleId => raw['partner_vehicle_id'] as String?;
  String? get partnerEnergy => raw['partner_energy'] as String?;
  List<String> get partnerVehicleTypes =>
      [for (final t in (raw['partner_vehicle_types'] as List?) ?? const []) '$t'];
  PlateColours? get partnerPlateColours => plateColoursFromJson(raw['partner_plate_colours']);
  double? get partnerRating => _d(raw['partner_rating']);

  /// The driver's completed trips when they bid or took the ride, stamped by
  /// the server (migration 0237): 0 when the stamp is empty (a new driver).
  /// Null when the row has no such column (a server from before 0237), so
  /// the cards show the rating alone rather than calling everyone new.
  int? get partnerTrips => raw.containsKey('partner_trips') ? (_i(raw['partner_trips']) ?? 0) : null;
  String? get partnerPhoto => raw['partner_photo'] as String?;
  /// Where the driver was when they accepted or made their offer.
  double? get partnerAcceptLat => _d(raw['partner_accept_lat']);
  double? get partnerAcceptLng => _d(raw['partner_accept_lng']);
  double? get partnerLiveLat => _d(raw['partner_live_lat']);
  double? get partnerLiveLng => _d(raw['partner_live_lng']);
  double? get partnerLiveHeading => _d(raw['partner_live_heading']);

  /// The passenger's own live position, as their phone last shared it.
  double? get userLiveLat => _d(raw['user_live_lat']);
  double? get userLiveLng => _d(raw['user_live_lng']);
  DateTime? get userLiveAt => _t(raw['user_live_at']);
  String? get otp => raw['otp'] as String?;
  DateTime? get createdAt => _t(raw['created_at']);
  DateTime? get acceptedAt => _t(raw['accepted_at']);
  DateTime? get arrivedAt => _t(raw['arrived_at']);
  DateTime? get startedAt => _t(raw['started_at']);
  DateTime? get completedAt => _t(raw['completed_at']);

  /// When the driver ended the trip before the drop-off (migration 0104).
  DateTime? get endedEarlyAt => _t(raw['ended_early_at']);

  /// Handed over mid-trip (migration 0199): where the new driver meets the
  /// car, and whether the passenger is with them yet.
  DateTime? get handedOverAt => _t(raw['handed_over_at']);
  DateTime? get handoverBoardedAt => _t(raw['handover_boarded_at']);
  double? get handoverMeetLat => _d(raw['handover_meet_lat']);
  double? get handoverMeetLng => _d(raw['handover_meet_lng']);

  /// The new driver is on their way to the car.
  bool get handoverMeeting => handedOverAt != null && handoverBoardedAt == null;
  DateTime? get cancelledAt => _t(raw['cancelled_at']);
  String? get cancelReason => raw['cancel_reason'] as String?;
  double? get tollCharges => _d(raw['toll_charges']);
  double? get otherCharges => _d(raw['other_charges']);
  String? get otherChargesNote => raw['other_charges_note'] as String?;

  /// How the ride's fare is priced in its region (migration 0119): whole
  /// amounts, and the tax on top.
  RegionPricing get pricing => RegionPricing.fromRide(raw);

  /// A fare on this ride, as its region shows fares: without decimals
  /// where they are whole. Tolls and other charges keep theirs.
  String fareText(num? amount) => formatMoney(amount, currency, pricing.fareDecimals);

  /// The taxes on the fare (and its surcharges), when the region has any.
  double get taxAmount {
    final f = effectiveFare;
    return f == null ? 0 : pricing.taxOn(f);
  }

  /// The region's surcharges on the fare (its scheduled rules at booking).
  double get surchargeAmount {
    final f = effectiveFare;
    return f == null ? 0 : pricing.surchargesOn(f);
  }

  /// The surcharge and tax lines on the fare, as the receipt shows them.
  List<ChargeLine> get chargeLines {
    final f = effectiveFare;
    return f == null ? const [] : pricing.linesFor(f);
  }

  /// Fare plus its surcharges and taxes, the tolls and other charges the
  /// driver declared, and fees carried over from an earlier ride.
  double? get totalDue {
    final f = effectiveFare;
    if (f == null) return null;
    return f + surchargeAmount + taxAmount + (tollCharges ?? 0) + (otherCharges ?? 0) + (priorFees ?? 0);
  }

  /// What the rider's GET.coin paid towards [totalDue] (migration 0101; the
  /// driver is credited the same amount).
  double get fareCoinsValue => _d(raw['fare_coins_value']) ?? 0;

  /// The platform's cut, stamped on the ride when it was charged to the
  /// driver's GET.credit (`wallet_charge_ride_commission`).
  double? get commissionAmount => _d(raw['commission_amount']);
  double? get commissionRate => _d(raw['commission_rate']);
  double? get fareCoinsUsed => _d(raw['fare_coins_used']);

  /// The ride's promo code (migration 0242): the code the server kept at
  /// booking, its estimate, and once the trip completed, what it gave.
  /// Null when the ride has none.
  RidePromo? get promo => RidePromo.of(raw);

  /// The promo discount settled on the completed trip (0 when none).
  double get promoDiscount => _d(raw['promo_discount']) ?? 0;

  /// What is left for the driver to collect after GET.coin and the promo
  /// (the promo's amount goes to the driver's GET.wallet).
  double? get cashDue {
    final t = totalDue;
    if (t == null) return null;
    final left = t - fareCoinsValue - promoDiscount;
    return left < 0 ? 0 : (left * 100).roundToDouble() / 100;
  }

  /// Where paying for the completed ride stands (migration 0142); null on a
  /// ride the database doesn't track payment for, which asks nothing.
  RidePaymentStatus? get paymentStatus => RidePaymentStatus.parse(raw['payment_status']);
  RidePayMethod? get paidMethod => RidePayMethod.parse(raw['paid_method']);
  double? get paidAmount => _d(raw['paid_amount']);
  DateTime? get paidAt => _t(raw['paid_at']);
  DateTime? get cancelRequestedAt => _t(raw['cancel_requested_at']);
  String? get cancelRequestedBy => raw['cancel_requested_by'] as String?;

  /// What became of the last cancellation request when it ended without the
  /// ride ending (migration 0191): 'declined' or 'expired' (nobody answered).
  String? get cancelRequestOutcome => raw['cancel_request_outcome'] as String?;

  /// Who had asked: 'rider' or 'partner'.
  String? get cancelRequestOutcomeBy => raw['cancel_request_outcome_by'] as String?;

  DateTime? get cancelRequestOutcomeAt => _t(raw['cancel_request_outcome_at']);

  /// The support ticket opened for it, when there is one.
  String? get cancelTicketId => raw['cancel_ticket_id'] as String?;

  /// Trip safety signals (migration 0154): why the start was flagged, when,
  /// when the phones were found apart mid-trip, and when the passenger said
  /// they were OK.
  String? get startFlag => raw['start_flag'] as String?;
  DateTime? get startFlagAt => _t(raw['start_flag_at']);
  DateTime? get separatedAt => _t(raw['separated_at']);
  DateTime? get safetyAckAt => _t(raw['safety_ack_at']);

  /// My Ride (migration 0160): the favourite drivers this request is offered
  /// to first, until when, the distance cap the server applied, and when it
  /// was opened to everybody / widened to the service's max radius. All
  /// null on an ordinary request (and on rows from before 0160).
  List<String> get targetDriverIds {
    final v = raw['target_driver_ids'];
    return [for (final id in v is List ? v : const []) '$id'];
  }
  DateTime? get targetedUntil => _t(raw['targeted_until']);
  double? get myRideMaxKm => _d(raw['my_ride_max_km']);
  DateTime? get fallbackPushedAt => _t(raw['fallback_pushed_at']);
  DateTime? get widenedPushedAt => _t(raw['widened_pushed_at']);

  /// GET.now (migration 0161): the driver booked directly with their QR
  /// code, and the code it was booked through. Null on every other request.
  String? get directDriverId => raw['direct_driver_id'] as String?;
  String? get directQrId => raw['direct_qr_id'] as String?;

  /// Booked directly with a driver's GET.now code: offered to that driver
  /// alone, with no automatic fallback (the rider may still offer it to all).
  bool get isDirectBooking => directDriverId != null;

  /// Booked with My Ride: offered to favourites (now or earlier).
  bool get isMyRide => targetDriverIds.isNotEmpty;

  /// Still only for the favourites at [now].
  bool myRideWindowOpenAt(DateTime now) =>
      myRideWindowOpen(targets: targetDriverIds, targetedUntil: targetedUntil, now: now);

  /// What is left of the favourites window at [now]; null when none runs.
  Duration? myRideWindowRemainingAt(DateTime now) =>
      myRideWindowRemaining(targets: targetDriverIds, targetedUntil: targetedUntil, now: now);

  /// Whether driver [me] pins this request with a gold star.
  /// A GET.now booking is targeted at its driver too, but that is the
  /// passenger's QR scan, not My Ride: it is starred only when the rider
  /// really is one of [me]'s regulars.
  bool starredFor(String? me, Set<String> favouriteRiderIds) => isStarredFor(
    riderId: riderId,
    targetDriverIds: isDirectBooking ? const [] : targetDriverIds,
    me: me,
    favouriteRiderIds: favouriteRiderIds,
  );

  String get pickupLabel => pickupName ?? pickupAddress ?? 'Pickup';
  String get dropLabel => dropName ?? dropAddress ?? 'Drop-off';

  /// The doors the rider chose at an airport (migration 0249; named by the
  /// server).
  String? get pickupDoor => _nonEmpty(raw['pickup_door_name']);

  /// The pickup door's id, and the airport or place (0258) the pickup is in.
  String? get pickupDoorId => _nonEmpty(raw['pickup_door_id']?.toString());
  String? get pickupAreaId => _nonEmpty(raw['airport_pickup_id']?.toString());
  String? get dropDoor => _nonEmpty(raw['drop_door_name']);

  /// The type of the Multi-Gate place or airport each end is at (0264,
  /// stamped by the server: a `place_types` key); null for none.
  String? get pickupPlaceType => _nonEmpty(raw['pickup_place_type']);
  String? get dropPlaceType => _nonEmpty(raw['drop_place_type']);

  /// A pickup the airport keeps for its waiting drivers (0249).
  bool get airportHold => raw['airport_hold'] == true;

  static String? _nonEmpty(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  /// Stops between pickup and drop-off, in order (migration 0098).
  List<Place> get stops => parseRideStops(raw['stops']);

  /// "Pet with me" (migration 0247): each pet's type and size, and its photo
  /// once the driver has taken the ride (an open request keeps the photos
  /// aside, for the rider only).
  List<RidePet> get pets => parseRidePets(raw['pets']);

  /// "Assistance required" (migration 0248): the help picked, and the
  /// rider's note once the driver has taken the ride (an open request keeps
  /// the note aside, for the rider only). Null for none.
  RideAssistance? get assistance => RideAssistance.fromJson(raw['assistance']);

  /// What the rider's pets and assistance added to the fare (0248); the
  /// fare includes them.
  List<OptionChargeLine> get optionCharges => parseOptionCharges(raw['option_charges']);

  /// The names the rider's options were booked under (0248), by option id.
  Map<String, String> get optionNames => {
    if (raw['option_names'] is Map)
      for (final e in (raw['option_names'] as Map).entries)
        if (e.key is String && e.value is String && (e.value as String).trim().isNotEmpty)
          e.key as String: (e.value as String).trim(),
  };

  /// An option's name as booked, when the admin had renamed it.
  String? renamedOption(RideOptionKind k) => bookedOptionName(optionNames, k);

  /// The extras it carries, as the driver reads them before answering
  /// (core/ride_extras.dart, migration 0253).
  List<RideExtra> get extras =>
      rideExtrasOf(pets: pets, assistance: assistance, names: optionNames, passengers: passengers);

  /// Freight (migration 0267): what the rider sends, and a photo of it in
  /// the private `ride-cargo` bucket (the rider, the driver who takes it and
  /// admins open it). Null on a ride.
  String? get cargoDescription => _nonEmpty(raw['cargo_description']);
  String? get cargoPhotoPath => _nonEmpty(raw['cargo_photo_path']);
  bool get isFreight => cargoDescription != null;

  /// Proof of delivery (0267): the driver's photos at pickup and at
  /// drop-off, and the sender's signature, in the private `ride-cargo` bucket.
  String? get pickupProofPath => _nonEmpty(raw['pickup_proof_path']);
  String? get dropoffProofPath => _nonEmpty(raw['dropoff_proof_path']);
  String? get signaturePath => _nonEmpty(raw['delivery_signature_path']);

  /// What waiting at pickup added to the fare once the trip started, and
  /// the fee owed for cancelling after the driver arrived.
  int? get waitingMinutes => _i(raw['freight_waiting_minutes']);
  double? get waitingFee => _d(raw['freight_waiting_fee']);
  double? get cancelFee => _d(raw['freight_cancel_fee']);

  /// The value the sender declared, and whom the tracking link goes to.
  double? get declaredValue => _d(raw['declared_value']);
  String? get recipientName => _nonEmpty(raw['recipient_name']);
  String? get recipientPhone => _nonEmpty(raw['recipient_phone']);

  /// The fare the trip will actually be billed at.
  double? get effectiveFare => _d(raw['ride_fare']) ?? fare;
}

class Profile {
  Profile(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  String? get displayId => raw['display_id'] as String?;
  String? get name => raw['name'] as String?;
  String? get phone => raw['phone'] as String?;
  String? get email => raw['email'] as String?;
  String? get avatarUrl => (raw['avatar_url'] ?? raw['profile_image']) as String?;
  String? get referralCode => raw['referral_code'] as String?;
  int get totalRides => _i(raw['total_rides']) ?? 0;
  /// The account's rating as a rider, where the server keeps one; null until
  /// then (the menu says "New" rather than inventing stars).
  double? get riderRating => _d(raw['rider_rating']);

  /// How many of the rider's latest ratings [riderRating] averages (0269).
  int get riderRatingsCount => _i(raw['rider_ratings_count']) ?? 0;
  String? get status => raw['status'] as String?;
  String? get nationality => raw['nationality'] as String?;
  String? get idNumber => raw['ic'] as String?;
  String? get address => raw['address'] as String?;
  String? get idImage => raw['id_image'] as String?;
}

class Partner {
  Partner(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  String? get name => raw['name'] as String?;
  String? get phone => raw['phone'] as String?;
  String? get vehicle => raw['vehicle'] as String?;
  String? get plate => raw['plate'] as String?;
  double? get rating => _d(raw['rating']);
  String? get status => raw['status'] as String?;
  String? get avatarUrl => raw['avatar_url'] as String?;

  /// An admin has approved the account (`approved`, or a permit status):
  /// it can take work. Mirrors `partnerStatusView(...).canDrive`.
  bool get approved {
    final s = (status ?? '').trim();
    return s == 'approved' || s.startsWith('permit-');
  }
}

class WalletBalance {
  WalletBalance(this.walletType, this.balance, this.currency);
  final String walletType;
  final double balance;
  final String currency;

  factory WalletBalance.fromRow(Map<String, dynamic> r) => WalletBalance(
        r['wallet_type'] as String,
        _d(r['balance']) ?? 0,
        (r['currency'] as String?) ?? 'MYR',
      );

  String get label => switch (walletType) {
        'get_wallet' => 'GET.wallet',
        'get_coin' => 'GET.coin',
        'get_credit' || 'credit' => 'GET.credit',
        _ => walletType,
      };
}

class WalletTransaction {
  WalletTransaction(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  String get walletType => raw['wallet_type'] as String;
  String get kind => raw['kind'] as String;
  double get amount => _d(raw['amount']) ?? 0;
  double? get balanceAfter => _d(raw['balance_after']);
  String? get method => raw['method'] as String?;
  String? get note => raw['note'] as String?;
  String? get status => raw['status'] as String?;
  DateTime? get createdAt => _t(raw['created_at']);
}

class EmergencyContact {
  EmergencyContact({required this.id, required this.name, required this.phone});
  final String id;
  final String name;
  final String phone;

  factory EmergencyContact.fromRow(Map<String, dynamic> r) => EmergencyContact(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '',
        phone: (r['phone'] as String?) ?? '',
      );
}

class SupportTicket {
  SupportTicket(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  int? get number => _i(raw['ticket_number']);
  String get subject => (raw['subject'] as String?) ?? 'Support';
  String get status => (raw['status'] as String?) ?? 'open';
  String? get lastMessage => raw['last_message'] as String?;
  DateTime? get lastMessageAt => _t(raw['last_message_at']) ?? _t(raw['created_at']);
  int get unreadUser => _i(raw['unread_user']) ?? 0;
}

class SupportMessage {
  SupportMessage(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  String get senderRole => (raw['sender_role'] as String?) ?? 'user';
  String? get senderName => raw['sender_name'] as String?;
  String get type => (raw['type'] as String?) ?? 'text';
  String? get body => raw['body'] as String?;
  String? get mediaUrl => raw['media_url'] as String?;

  /// A voice note's length.
  Duration? get mediaDuration => switch (raw['media_duration']) {
    final num s => Duration(milliseconds: (s * 1000).round()),
    _ => null,
  };
  DateTime? get createdAt => _t(raw['created_at']);
  bool get fromUser => senderRole == 'user';
}
