// The store review account's repositories (0333 follow-up). The module
// repositories switch to these while the store review account is signed in
// (each provider asks storeReviewProvider): bookings, family, scheduled jobs,
// SOS and money are kept on this phone alone, in [demoStoreProvider]. Their
// reads that only show settings or prices still ask the server; nothing is
// ever written, sent, charged, called or texted. The server's seal stays as
// it was: it would refuse every one of these writes anyway.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/commission.dart' show Geo;
import '../../core/city_to_city.dart';
import '../../core/city_to_city_seats.dart';
import '../../core/demo/demo_script.dart';
import '../../core/demo_mode.dart' show demoPlaces;
import '../../core/family.dart';
import '../../core/multi_day_hire.dart';
import '../../core/scheduled_rides.dart';
import '../../features/ride/demo_ride.dart' show demoRidesProvider;
import '../../features/store_review/demo_wallet.dart' show demoWalletProvider;
import '../../providers.dart';
import '../city_to_city_repository.dart';
import '../family_repository.dart';
import '../hourly_hire_repository.dart';
import '../models.dart';
import '../ride_repository.dart';
import '../safety_incident_repository.dart';
import '../scheduled_ride_repository.dart';
import '../wallet_pay_repository.dart';

// ---- The store ------------------------------------------------------------------------------------------

/// Everything the demo account has booked or changed, on this phone alone.
class DemoStoreState {
  const DemoStoreState({
    this.scheduled = const {},
    this.hire = const {},
    this.c2c = const {},
    this.family,
    this.taken = const {},
    this.interest = const {},
    this.given = const {},
    this.sos = 0,
  });

  /// Rides for later (scheduled_rides rows), by id.
  final Map<String, Map<String, dynamic>> scheduled;

  /// Hires for several days (hire_bookings rows), by id.
  final Map<String, Map<String, dynamic>> hire;

  /// City to City requests and seats (c2c_bookings rows), by id.
  final Map<String, Map<String, dynamic>> c2c;

  /// The demo family's members (family_mine's members); null until first read.
  final List<Map<String, dynamic>>? family;

  /// Demo scheduled jobs the demo driver took, gave back, or showed interest in.
  final Set<String> taken, interest, given;

  /// How many demo SOS were "raised" (none ever sent).
  final int sos;

  DemoStoreState copyWith({
    Map<String, Map<String, dynamic>>? scheduled,
    Map<String, Map<String, dynamic>>? hire,
    Map<String, Map<String, dynamic>>? c2c,
    List<Map<String, dynamic>>? family,
    Set<String>? taken,
    Set<String>? interest,
    Set<String>? given,
    int? sos,
  }) => DemoStoreState(
    scheduled: scheduled ?? this.scheduled,
    hire: hire ?? this.hire,
    c2c: c2c ?? this.c2c,
    family: family ?? this.family,
    taken: taken ?? this.taken,
    interest: interest ?? this.interest,
    given: given ?? this.given,
    sos: sos ?? this.sos,
  );
}

final demoStoreProvider = NotifierProvider<DemoStore, DemoStoreState>(DemoStore.new);

class DemoStore extends Notifier<DemoStoreState> {
  int _n = 0;

  @override
  DemoStoreState build() => const DemoStoreState();

  String newId(String kind) => 'demo-$kind-${++_n}';

  void putScheduled(Map<String, dynamic> row) =>
      state = state.copyWith(scheduled: {...state.scheduled, '${row['id']}': row});

  void putHire(Map<String, dynamic> row) => state = state.copyWith(hire: {...state.hire, '${row['id']}': row});

  void putC2c(Map<String, dynamic> row) => state = state.copyWith(c2c: {...state.c2c, '${row['id']}': row});

  void setFamily(List<Map<String, dynamic>> members) => state = state.copyWith(family: members);

  void take(String id, bool on) {
    final taken = {...state.taken}, given = {...state.given};
    if (on) {
      taken.add(id);
      given.remove(id);
    } else {
      taken.remove(id);
      given.add(id);
    }
    state = state.copyWith(taken: taken, given: given);
  }

  void interest(String id, bool on) =>
      state = state.copyWith(interest: on ? {...state.interest, id} : ({...state.interest}..remove(id)));

  void sos() => state = state.copyWith(sos: state.sos + 1);
}

String _now() => DateTime.now().toUtc().toIso8601String();

// ---- Rides: now and for later ------------------------------------------------------------------------

/// Where RideRepository.createRequest puts the demo account's booking: a
/// ride now on this phone ([demoRidesProvider], which demo drivers answer),
/// or a booking for later in [demoStoreProvider].
class DemoRideSink implements RideDemoSink {
  DemoRideSink(this._ref);
  final Ref _ref;

  @override
  RideRequest now(Map<String, dynamic> row) {
    final clean = {...row}..remove('id');
    // A hire with no drop-off ends near where it started.
    if (clean['drop_lat'] == null || clean['drop_lng'] == null) {
      final lat = (clean['pickup_lat'] as num?)?.toDouble() ?? demoPlaces[0].$3;
      final lng = (clean['pickup_lng'] as num?)?.toDouble() ?? demoPlaces[0].$4;
      clean.addAll({'drop_lat': lat + 0.02, 'drop_lng': lng + 0.015, 'drop_name': clean['drop_name'] ?? 'As directed'});
    }
    return _ref.read(demoRidesProvider.notifier).create({...clean, 'demo_module': demoModuleOf(row)});
  }

  @override
  Future<ScheduledRide> later(Map<String, dynamic> row, DateTime at) =>
      _ref.read(scheduledRideRepositoryProvider).schedule(row, at);
}

/// Demo scheduled rides (the rider's) and demo scheduled jobs (the driver's).
class DemoScheduledRideRepository extends ScheduledRideRepository {
  DemoScheduledRideRepository(super.db, this._ref);
  final Ref _ref;

  DemoStore get _store => _ref.read(demoStoreProvider.notifier);
  DemoStoreState get _state => _ref.read(demoStoreProvider);

  @override
  Future<ScheduledRide> schedule(Map<String, dynamic> request, DateTime pickupAt) async {
    final row = <String, dynamic>{
      ...request,
      'id': _store.newId('scheduled'),
      'pickup_at': pickupAt.toUtc().toIso8601String(),
      'status': 'scheduled',
      'scheduling_fee': 0,
      'request': request,
      'created_at': _now(),
    };
    _store.putScheduled(row);
    return ScheduledRide.fromRow(row);
  }

  @override
  Future<List<ScheduledRide>> mine(String uid) async {
    final rows = _state.scheduled.values.toList()
      ..sort((a, b) => '${a['pickup_at']}'.compareTo('${b['pickup_at']}'));
    return [for (final r in rows) ScheduledRide.fromRow(r)];
  }

  @override
  Future<ScheduledRide> cancel(String id, {String? reason}) async {
    final r = _state.scheduled[id];
    if (r == null) throw const ScheduleError('This demo booking has gone.');
    final row = {...r, 'status': 'cancelled', 'cancelled_by': 'rider', 'cancel_reason': reason};
    _store.putScheduled(row);
    return ScheduledRide.fromRow(row);
  }

  @override
  Future<double> owedFees() async => 0;

  List<Map<String, dynamic>> get _jobs => demoOpenScheduledRows(DateTime.now());

  @override
  Future<List<ScheduledRide>> open() async => [
    for (final r in _jobs)
      if (!_state.taken.contains(r['id'])) ScheduledRide.fromRow(r),
  ];

  @override
  Future<List<ScheduledRide>> accepted(String uid) async => [
    for (final r in _jobs)
      if (_state.taken.contains(r['id'])) ScheduledRide.fromRow({...r, 'status': 'assigned', 'partner_id': uid}),
  ];

  @override
  Future<void> accept(String id) async => _store.take(id, true);

  @override
  Future<void> release(String id) async => _store.take(id, false);

  @override
  Future<List<UpcomingBooking>> upcoming() async => const [];

  @override
  Future<void> setInterest(String id, bool on) async => _store.interest(id, on);

  @override
  Future<void> handOver(String id, String code) async => _store.take(id, false);

  @override
  Future<void> requestDriver(String id, String code) async {}

  @override
  Future<List<ScheduledOffer>> offers() async => const [];

  @override
  Future<void> answerOffer(String offerId, {required bool accept}) async {}

  @override
  Future<void> withdrawOffer(String offerId) async {}
}

// ---- Hire for several days -----------------------------------------------------------------------------

/// "Daily hire", "Weekly hire", "Monthly hire".
String demoHireTitle(String package) => switch (package) {
  hirePackageWeekly => 'Weekly hire',
  hirePackageMonthly => 'Monthly hire',
  _ => 'Daily hire',
};

class DemoHourlyHireRepository extends HourlyHireRepository {
  DemoHourlyHireRepository(super.client, this._ref);
  final Ref _ref;

  DemoStore get _store => _ref.read(demoStoreProvider.notifier);
  DemoStoreState get _state => _ref.read(demoStoreProvider);
  bool _takes = true;

  /// The booking and a demo scheduled ride for each of its days (up to 31
  /// listed), all on the phone.
  @override
  Future<HireDaysBooking> book(Map<String, dynamic> row, Map<String, dynamic> booking) async {
    final id = _store.newId('hire');
    final package = '${booking['package'] ?? hirePackageDaily}';
    final first = DateTime.tryParse('${booking['first_at']}') ?? DateTime.now().add(const Duration(days: 1));
    final days = (booking['days'] is num ? (booking['days'] as num).round() : 1).clamp(1, 366);
    final hours = booking['hours'] is num ? (booking['hours'] as num).toDouble() : 8.0;
    final perDay = row['fare'] is num ? (row['fare'] as num).toDouble() : 0.0;
    final hire = <String, dynamic>{
      'id': id,
      'package': package,
      'quote': {'title': demoHireTitle(package), 'days': days},
      'service': row['service'],
      'status': 'booked',
      'first_at': first.toUtc().toIso8601String(),
      'days': days,
      'hours_per_day': hours,
      'overnight': booking['overnight'] == true,
      'same_driver': booking['same_driver'] != false,
      'payment_plan': booking['payment_plan'],
      'payment_state': 'none',
      'price': perDay * days,
      'currency': row['currency'],
      'pickup_address': row['pickup_address'] ?? row['pickup_name'],
      'drop_address': row['drop_address'] ?? row['drop_name'],
      'rider_id': row['rider_id'],
      'weekdays': booking['weekdays'],
      'periods': booking['periods'],
      'created_at': _now(),
    };
    _store.putHire(hire);
    for (var d = 0; d < days && d < 31; d++) {
      final at = first.add(Duration(days: d));
      _store.putScheduled({
        ...row,
        'id': '$id-day-${d + 1}',
        'pickup_at': at.toUtc().toIso8601String(),
        'status': 'scheduled',
        'hire_package': package,
        'hire_hours': hours,
        'hire_booking_id': id,
        'hire_day_no': d + 1,
        'hire_days': days,
        'hire_title': demoHireTitle(package),
        'request': row,
      });
    }
    return HireDaysBooking.fromRow(hire);
  }

  @override
  Future<List<HireDaysBooking>> myBookings() async => [
    for (final r in _state.hire.values.toList().reversed) HireDaysBooking.fromRow(r),
  ];

  @override
  Future<HireDaysBooking?> booking(String id) async {
    final r = _state.hire[id];
    return r == null ? null : HireDaysBooking.fromRow(r);
  }

  @override
  Future<({bool free, double fee, double refund, DateTime? freeUntil, bool started})> cancelQuote(String id) async =>
      (free: true, fee: 0.0, refund: 0.0, freeUntil: null, started: false);

  @override
  Future<void> cancelBooking(String id, {String? reason}) async {
    final r = _state.hire[id];
    if (r != null) _store.putHire({...r, 'status': 'cancelled'});
    for (final s in _state.scheduled.values.toList()) {
      if (s['hire_booking_id'] == id) _store.putScheduled({...s, 'status': 'cancelled'});
    }
  }

  @override
  Future<List<({String id, int day, DateTime at, String status, String? partnerId, String? rideId})>> bookingDays(
    String id,
  ) async {
    final rows = [for (final s in _state.scheduled.values) if (s['hire_booking_id'] == id) s]
      ..sort((a, b) => (a['hire_day_no'] as int).compareTo(b['hire_day_no'] as int));
    return [
      for (final s in rows)
        (
          id: '${s['id']}',
          day: s['hire_day_no'] as int,
          at: DateTime.tryParse('${s['pickup_at']}')?.toLocal() ?? DateTime.now(),
          status: '${s['status']}',
          partnerId: null,
          rideId: null,
        ),
    ];
  }

  @override
  Future<bool> takesHire() async => _takes;

  @override
  Future<void> setTakesHire(bool on) async => _takes = on;
}

// ---- City to City ------------------------------------------------------------------------------------

class DemoCityToCityRepository extends CityToCityRepository {
  DemoCityToCityRepository(super.db, this._ref);
  final Ref _ref;

  DemoStore get _store => _ref.read(demoStoreProvider.notifier);
  DemoStoreState get _state => _ref.read(demoStoreProvider);

  @override
  Future<C2cBooking> book(Map<String, dynamic> row) async {
    final b = {
      ...row,
      'id': _store.newId('c2c'),
      'rider_id': _ref.read(currentUserIdProvider),
      'status': 'open',
      'created_at': _now(),
    };
    _store.putC2c(b);
    return C2cBooking.fromRow(b);
  }

  @override
  Future<List<C2cBooking>> myTrips() async => [
    for (final r in _state.c2c.values.toList().reversed) C2cBooking.fromRow(r),
  ];

  @override
  Future<C2cBooking?> booking(String id) async {
    final r = _state.c2c[id];
    return r == null ? null : C2cBooking.fromRow(r);
  }

  @override
  Future<List<C2cOffer>> offers(String bookingId) async => const [];

  @override
  Future<({double fee, String feeStatus})> cancel(String bookingId, {String? reason}) async {
    final r = _state.c2c[bookingId];
    if (r != null) _store.putC2c({...r, 'status': 'cancelled', 'cancelled_by': 'rider'});
    return (fee: 0.0, feeStatus: 'none');
  }

  @override
  Future<void> rateDriver(String bookingId, int stars, {String? comment}) async {}

  /// Two demo trips between the places searched, tomorrow morning and
  /// afternoon, with a meeting point each in Kuala Lumpur.
  @override
  Future<List<C2cTrip>> searchTrips({required Geo from, required Geo to, DateTime? day, int seats = 1}) async {
    final base = day ?? DateTime.now().add(const Duration(days: 1));
    String name(Geo g, String fallback) => g.city ?? g.state ?? fallback;
    C2cTrip trip(int n, int hour, String driver, double price) {
      final p = demoPlaces[n == 1 ? 3 : 4];
      return C2cTrip.fromJson({
        'id': 'demo-trip-$n',
        'from_name': name(from, 'Kuala Lumpur'),
        'to_name': name(to, 'Penang'),
        'leave_at': DateTime(base.year, base.month, base.day, hour).toUtc().toIso8601String(),
        'seats_total': 4,
        'seats_left': 3,
        'seat_price': price,
        'meeting_points': [
          {'name': p.$1, 'address': p.$2, 'lat': p.$3, 'lng': p.$4, 'minutes': 0},
        ],
        'driver_name': '$driver (demo)',
        'driver_rating': 4.8,
        'car': 'Toyota Innova',
        'plate': 'DEMO 7$n',
        'max_per_booking': 3,
      });
    }

    return [trip(1, 9, 'Patrick', 45), trip(2, 15, 'Gomer', 40)];
  }

  @override
  Future<C2cTrip?> tripForRider(String id) async {
    final all = await searchTrips(from: const Geo(), to: const Geo());
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  Future<C2cPayInfo> seatPayInfo(String tripId) async => C2cPayInfo.fromJson({
    'when': 'after',
    'walletBalance': _ref.read(demoWalletProvider).wallet,
    'coinBalance': _ref.read(demoWalletProvider).coin,
  });

  @override
  Future<({String id, String status})> bookSeat({
    required String tripId,
    required int seats,
    required Map<String, dynamic> pickup,
    required C2cPayment payment,
    List<C2cPassenger> passengers = const [],
    C2cPayWay? way,
    double? expected,
    Map<String, dynamic>? parcel,
    String? note,
    FamilyPick? family,
  }) async {
    final id = _store.newId('seat');
    _store.putC2c({
      'id': id,
      'trip_id': tripId,
      'rider_id': _ref.read(currentUserIdProvider),
      'pickup_name': pickup['name'] ?? 'Meeting point',
      'drop_name': 'Destination',
      'leave_at': DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String(),
      'fare': expected ?? 0,
      'passengers': seats,
      'payment': payment.key,
      'status': 'booked',
      'created_at': _now(),
    });
    return (id: id, status: 'booked');
  }

  @override
  Future<C2cDriverFeed> driverFeed() async => const C2cDriverFeed(approved: true, hasArea: true);

  @override
  Future<List<C2cBooking>> driverTrips() async => const [];

  @override
  Future<List<C2cTrip>> driverSeatTrips() async => const [];
}

// ---- Family ----------------------------------------------------------------------------------------------

/// The demo family: the reviewer hosts it; every change stays on the phone.
class DemoFamilyRepository extends FamilyRepository {
  DemoFamilyRepository(super.db, this._ref);
  final Ref _ref;

  DemoStore get _store => _ref.read(demoStoreProvider.notifier);

  List<Map<String, dynamic>> get _members {
    final have = _ref.read(demoStoreProvider).family;
    if (have != null) return have;
    final made = demoFamilyMembers(DateTime.now());
    _store.setFamily(made);
    return made;
  }

  Future<String> _hostName() async {
    try {
      return (await _ref.read(profileProvider.future))?.name ?? 'You';
    } catch (_) {
      return 'You';
    }
  }

  @override
  Future<FamilyView> mine({Geo? place}) async =>
      FamilyView.fromJson(demoFamilyJson(hostName: await _hostName(), members: _members));

  Map<String, dynamic> _add(Map<String, dynamic> m) {
    _store.setFamily([..._members, m]);
    return m;
  }

  @override
  Future<FamilyMember> invite({
    required String phone,
    required String name,
    String? relation,
    double? monthlyLimit,
    double? perRideLimit,
    List<String>? services,
    FamilyLocationRule location = FamilyLocationRule.ride,
    Geo? place,
  }) async => FamilyMember.fromJson(_add({
    'id': _store.newId('member'),
    'name': name,
    'kind': 'member',
    // A demo invite is never sent: it shows as accepted at once.
    'status': 'active',
    'relation': relation,
    'phone': phone,
    'monthlyLimit': monthlyLimit,
    'perRideLimit': perRideLimit,
    'services': services,
    'location': location.db,
    'locationNow': location.db,
    'limit': monthlyLimit ?? 0,
    'left': monthlyLimit ?? 0,
  }));

  @override
  Future<FamilyMember> addChild({
    required String name,
    required String birthDate,
    String? photoUrl,
    String? relation,
    List<String>? services,
    Geo? place,
  }) async => FamilyMember.fromJson(_add({
    'id': _store.newId('member'),
    'name': name,
    'kind': 'child',
    'status': 'active',
    'relation': relation,
    'birthDate': birthDate,
    'services': services,
    'location': 'ride',
    'locationNow': 'ride',
  }));

  @override
  Future<FamilyMember> updateMember(String id, Map<String, dynamic> patch) async {
    final list = [..._members];
    final i = list.indexWhere((m) => m['id'] == id);
    if (i < 0) throw StateError('This demo member has gone.');
    final next = {...list[i], ...patch};
    if (patch['monthlyLimit'] is num) {
      final limit = (patch['monthlyLimit'] as num).toDouble();
      final spent = (next['spent'] is num) ? (next['spent'] as num).toDouble() : 0.0;
      next['limit'] = limit;
      next['left'] = (limit - spent).clamp(0, double.infinity);
    }
    if (patch['location'] is String) next['locationNow'] = patch['location'];
    list[i] = next;
    _store.setFamily(list);
    return FamilyMember.fromJson(next);
  }

  @override
  Future<String> uploadChildPhoto(Uint8List bytes) async =>
      throw StateError('In the demo, photos are not uploaded. Add the child without one.');

  @override
  Future<void> removeMember(String id) async => _store.setFamily([for (final m in _members) if (m['id'] != id) m]);

  @override
  Future<void> requestCap(int wanted, {String? reason}) async {}

  @override
  Future<List<FamilyInvite>> invites() async => const [];

  @override
  Future<void> respond(String memberId, {required bool join, List<String> shown = const []}) async {}

  @override
  Future<void> leave() async => throw StateError('You host the demo family, so you cannot leave it.');

  @override
  Future<void> consent({bool? acceptRaise, bool? shareAlways}) async {}

  /// The reviewer is the host: the Family row is for members' own trips.
  @override
  Future<FamilyPayOption?> payOption(String module, {Geo? place, double? amount}) async => null;

  /// Who the host may book for: every member, a child under 12 with an adult.
  @override
  Future<List<FamilyPassenger>> passengers(String module, {Geo? place}) async {
    final now = DateTime.now();
    return [
      for (final m in _members.map(FamilyMember.fromJson))
        FamilyPassenger(
          id: m.id,
          name: m.name,
          kind: m.kind,
          phone: m.phone,
          age: m.birthDate == null ? null : childAge(m.birthDate!, now),
          allowed: true,
          needsAdult: m.isChild && m.birthDate != null && childAge(m.birthDate!, now) < 12,
          code: m.isChild ? '4821' : null,
        ),
    ];
  }

  @override
  Future<FamilyTripStatus> tripStatus(String tripId) async => const FamilyTripStatus();

  @override
  Future<List<FamilyLiveItem>> live() async => [FamilyLiveItem.fromJson(demoFamilyLiveJson(DateTime.now()))];

  @override
  Future<FamilyChildCode?> childCode(String tripId) async => null;

  @override
  Future<FamilyChildCode?> newChildCode(String tripId) async => null;

  @override
  Future<List<FamilyViewLogEntry>> myViewLog() async => const [];
}

// ---- SOS and money --------------------------------------------------------------------------------------

/// An SOS from the demo account reaches nobody: it is counted on the phone.
class DemoSafetyIncidentRepository extends SafetyIncidentRepository {
  DemoSafetyIncidentRepository(super.db, this._ref);
  final Ref _ref;

  @override
  Future<String> raise({String? rideId, double? lat, double? lng}) async {
    _ref.read(demoStoreProvider.notifier).sos();
    return 'demo-sos-${_ref.read(demoStoreProvider).sos}';
  }

  @override
  Future<bool> shareLocation(String incidentId, double lat, double lng) async => true;
}

/// GET.wallet to GET.credit in the demo wallet.
class DemoCreditRechargeRepository extends CreditRechargeRepository {
  DemoCreditRechargeRepository(super.db, this._ref);
  final Ref _ref;

  @override
  Future<void> recharge(double amount) async {
    if (!_ref.read(demoWalletProvider.notifier).recharge(amount)) throw StateError('insufficient_balance');
  }
}

/// A QR payment out of the demo GET.wallet.
class DemoWalletPayRepository extends WalletPayRepository {
  DemoWalletPayRepository(super.db, this._ref);
  final Ref _ref;

  @override
  Future<WalletPayResult> pay(double amount, {required String note, bool redeemCoins = false}) async {
    if (!_ref.read(demoWalletProvider.notifier).pay(amount, note)) throw StateError('insufficient_balance');
    return WalletPayResult(walletPaid: amount, coinsUsed: 0, coinValue: 0);
  }
}
