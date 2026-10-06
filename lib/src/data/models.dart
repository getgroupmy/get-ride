/// Plain models over the shared Supabase tables. Column names match the live
/// `public` schema of the get.ride project exactly.
library;

import '../core/ride_stops.dart';
import 'geo_service.dart';

double? _d(Object? v) => v == null ? null : (v as num).toDouble();
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
  RideRequest(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  String? get riderId => raw['rider_id'] as String?;
  String? get riderName => raw['rider_name'] as String?;
  String? get riderPhone => raw['rider_phone'] as String?;
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
  int get passengers => _i(raw['passengers']) ?? 1;
  String? get note => raw['note'] as String?;
  RideStatus get status => RideStatus.parse(raw['status'] as String?);
  String? get partnerId => raw['partner_id'] as String?;
  String? get partnerName => raw['partner_name'] as String?;
  String? get partnerPhone => raw['partner_phone'] as String?;
  String? get partnerVehicle => raw['partner_vehicle'] as String?;
  String? get partnerPlate => raw['partner_plate'] as String?;
  double? get partnerRating => _d(raw['partner_rating']);
  double? get partnerLiveLat => _d(raw['partner_live_lat']);
  double? get partnerLiveLng => _d(raw['partner_live_lng']);
  String? get otp => raw['otp'] as String?;
  DateTime? get createdAt => _t(raw['created_at']);
  DateTime? get acceptedAt => _t(raw['accepted_at']);
  DateTime? get arrivedAt => _t(raw['arrived_at']);
  DateTime? get startedAt => _t(raw['started_at']);
  DateTime? get completedAt => _t(raw['completed_at']);
  DateTime? get cancelledAt => _t(raw['cancelled_at']);
  String? get cancelReason => raw['cancel_reason'] as String?;
  double? get tollCharges => _d(raw['toll_charges']);
  double? get otherCharges => _d(raw['other_charges']);
  String? get otherChargesNote => raw['other_charges_note'] as String?;

  /// Fare plus the tolls and other charges the driver declared.
  double? get totalDue {
    final f = effectiveFare;
    if (f == null) return null;
    return f + (tollCharges ?? 0) + (otherCharges ?? 0);
  }
  DateTime? get cancelRequestedAt => _t(raw['cancel_requested_at']);
  String? get cancelRequestedBy => raw['cancel_requested_by'] as String?;

  String get pickupLabel => pickupName ?? pickupAddress ?? 'Pickup';
  String get dropLabel => dropName ?? dropAddress ?? 'Drop-off';

  /// Stops between pickup and drop-off, in order (migration 0098).
  List<Place> get stops => parseRideStops(raw['stops']);

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
        'credit' => 'Credit',
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
  DateTime? get createdAt => _t(raw['created_at']);
  bool get fromUser => senderRole == 'user';
}
