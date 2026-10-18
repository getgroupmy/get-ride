// iPhone screenshots of the app's screens, for UI/UX review. Not a regression
// test: run with
//   SHOTS_DIR=/some/dir flutter test test/ios_shots_test.dart --update-goldens
// and look at the PNGs. Rendering problems (overflows, exceptions) are
// written to SHOTS_DIR/log.txt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/app.dart'
    show appTheme, routerProvider, maxAppTextScale;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/core/fare_coins.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart'
    show tripFixProvider;
import 'package:get_ride/src/features/ride/book_for_sheet.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart'
    show showPaymentSheet;
import 'package:get_ride/src/features/ride/location_share_button.dart';
import 'package:get_ride/src/features/ride/pickup_time_sheet.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart'
    show rideStreamProvider, riderPositionStreamProvider;
import 'package:get_ride/src/features/ride/searching_parts.dart'
    show showSearchCancelSheet;
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/session_access_card.dart';
import 'package:get_ride/src/core/session_access.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/data/ev_order_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/partner_onboarding_repository.dart';
import 'package:get_ride/src/data/vehicle_onboarding_repository.dart';
import 'package:get_ride/src/features/support/support_chat_screen.dart'
    show supportMessagesProvider;
import 'package:get_ride/src/features/support/support_screen.dart'
    show ticketsProvider;
import 'package:get_ride/src/widgets/search_select.dart';
import 'package:latlong2/latlong.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/my_ride_repository.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/permission_rules.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
import 'package:get_ride/src/data/trip_history_repository.dart';
import 'package:get_ride/src/core/trip_history.dart';
import 'package:get_ride/src/features/auth/passkey_sign_in_button.dart';
import 'package:get_ride/src/features/profile/emergency_contacts_screen.dart';
import 'package:get_ride/src/features/auth/set_pin_screen.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/partner/driver_wallet_pills.dart'
    show creditFloorProvider;
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/profile/referral_screen.dart';
import 'package:get_ride/src/features/settings/change_pin_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _outDir = Platform.environment['SHOTS_DIR'] ?? '';

// iPhone 15 / 16: 393 x 852 points at 3x, 59 pt status bar + Dynamic
// Island, 34 pt home indicator.
const _w = 393.0, _top = 59.0, _bottom = 34.0;

SupabaseClient _client() => SupabaseClient(
  'http://localhost',
  'anon',
  httpClient: MockClient((req) async {
    final p = req.url.path;
    const json = {'content-type': 'application/json'};
    final accept = req.headers['Accept'] ?? req.headers['accept'] ?? '';
    if (accept.contains('pgrst.object')) {
      // .single() / .maybeSingle() on nothing: what PostgREST answers.
      return http.Response(
        '{"code":"PGRST116","details":"The result contains 0 rows","hint":null,"message":"JSON object requested, multiple (or no) rows returned"}',
        406,
        headers: json,
        request: req,
      );
    }
    if (p.startsWith('/rest/v1/rpc/')) {
      return http.Response('[]', 200, headers: json, request: req);
    }
    if (p.startsWith('/rest/v1/')) {
      return http.Response(
        '[]',
        200,
        headers: {...json, 'content-range': '0-0/0'},
        request: req,
      );
    }
    if (p.startsWith('/auth/v1/')) {
      return http.Response(
        '{"error":"offline"}',
        401,
        headers: json,
        request: req,
      );
    }
    return http.Response('{}', 404, headers: json, request: req);
  }),
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

/// Signed in as "me"; the server never sees it.
final _dbIn = _client();

/// Nobody signed in: the sign-in screens.
final _dbOut = _client();

Future<void> _signIn() async {
  final exp =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
      1000;
  String b64(Map<String, Object> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final jwt =
      '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({'sub': 'me', 'exp': exp, 'role': 'authenticated', 'aud': 'authenticated'})}.sig';
  await _dbIn.auth.recoverSession(
    jsonEncode({
      'access_token': jwt,
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at': exp,
      'refresh_token': 'r',
      'user': {
        'id': 'me',
        'aud': 'authenticated',
        'role': 'authenticated',
        'phone': '+60123456789',
        'app_metadata': <String, Object>{},
        'user_metadata': <String, Object>{},
        'created_at': '2026-01-01T00:00:00Z',
      },
    }),
  );
}

RideRequest _ride(
  String id,
  String status, {
  double fare = 23.5,
  String from = 'Eco Majestic, Semenyih',
  String to = 'KLCC, Kuala Lumpur',
}) => RideRequest({
  'id': id,
  'rider_id': 'me',
  'status': status,
  'pickup_name': from,
  'drop_name': to,
  'pickup_lat': 2.95,
  'pickup_lng': 101.85,
  'drop_lat': 3.158,
  'drop_lng': 101.712,
  'fare': fare,
  'currency': 'MYR',
  'service': 'Ride',
  'payment_method': 'Cash',
  'created_at': '2026-10-17T08:12:00Z',
  'completed_at': '2026-10-17T08:48:00Z',
  'distance_km': 31.2,
});

class _FakeRides implements RideRepository {
  _FakeRides({this.ongoing});
  final RideRequest? ongoing;
  final List<RideRequest> past = const [];

  @override
  Future<RideRequest?> ongoingForRider() async => ongoing;

  @override
  Future<List<RideRequest>> ridesOnTheGo() async =>
      ongoing == null ? const [] : [ongoing!];

  @override
  Future<List<RideRequest>> history({int limit = 50}) async => past;

  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  Future<List<RideRequest>> openRequests({int limit = 30}) async => const [];

  @override
  Future<void> expireStaleOpen() async {}

  @override
  Future<Map<String, double>> nearbyDrivers(double lat, double lng) async =>
      const {};

  @override
  Future<RideRequest?> fetch(String id) async =>
      ongoing ?? (past.isEmpty ? null : past.first);

  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  Future<FareCoinRedemption?> redeemFareCoins(RideRequest r) async => null;

  @override
  Future<RequestViewers> viewers(String requestId) async =>
      const RequestViewers();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _eco = Place(
  name: 'Eco Majestic',
  address: 'Semenyih',
  point: LatLng(2.9300, 101.8300),
);
const _klcc = Place(
  name: 'KLCC',
  address: 'Kuala Lumpur',
  point: LatLng(2.9400, 101.8400),
);

/// Booking: no server, no bidding, a plain region.
class _BookingRides implements RideRepository {
  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<RideRequest?> ongoingForRider() async => null;

  @override
  Future<bool> biddingEnabledFor(
    LatLng pickup,
    Future<AreaInfo?> Function() area,
  ) async => false;

  @override
  Future<RegionPricing> pricingFor(
    LatLng pickup,
    Future<AreaInfo?> Function() area,
  ) async => RegionPricing.none;

  @override
  Future<String?> publicIp() async => null;

  @override
  Future<Map<String, double>> nearbyDrivers(double lat, double lng) async =>
      const {};

  @override
  Future<void> expireStaleOpen() async {}

  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// A ride the signed-in rider ("me") is on, with driver Ravi.
RideRequest _tracked(String status, {Map<String, dynamic> extra = const {}}) =>
    RideRequest({
      'id': 'r1',
      'rider_id': 'me',
      'partner_id': 'driver',
      'rider_name': 'Nur Aisyah',
      'partner_name': 'Ravi Kumar',
      'partner_phone': '+60198765432',
      'vehicle_plate': 'WXY 1234',
      'vehicle_model': 'Perodua Bezza',
      'vehicle_color': 'Silver',
      'status': status,
      'service': 'Ride',
      'fare': 23.5,
      'ride_fare': 23.5,
      'currency': 'MYR',
      'payment_mode': 'Cash',
      'pickup_name': 'Eco Majestic, Semenyih',
      'drop_name': 'KLCC, Kuala Lumpur',
      'pickup_lat': 2.93,
      'pickup_lng': 101.83,
      'drop_lat': 3.1579,
      'drop_lng': 101.7116,
      'distance_km': 31.2,
      'created_at': '2026-10-17T08:12:00Z',
      ...extra,
    });

/// A ride the signed-in driver ("me") has taken.
RideRequest _driving(String status, {Map<String, dynamic> extra = const {}}) =>
    RideRequest({
      ..._tracked(status).raw,
      'rider_id': 'rider',
      'partner_id': 'me',
      ...extra,
    });

RideRequest _request(
  String id,
  String from,
  String to,
  double fare, {
  double km = 5,
}) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'Ride',
  'fare': fare,
  'ride_fare': fare,
  'currency': 'MYR',
  'distance_km': km,
  'passengers': 1,
  'payment_mode': 'Cash',
  'rider_name': 'Aina',
  'pickup_name': from,
  'drop_name': to,
  'pickup_lat': 2.935,
  'pickup_lng': 101.835,
  'drop_lat': 3.0,
  'drop_lng': 101.75,
  'created_at': DateTime.now().toUtc().toIso8601String(),
});

final _approved = Partner({
  'id': 'p1',
  'status': 'approved',
  'name': 'Nur Aisyah',
  'partner_type': 'eHailing',
});

List<Override> _trackingOverrides(RideRequest ride) => [
  rideStreamProvider.overrideWith((ref, id) => Stream.value(ride)),
  riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
  tripFixProvider.overrideWithValue(() async => const LatLng(2.93, 101.83)),
  fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
];

/// From the home map to the confirm step: pickup by nudging the map,
/// destination from the recent places.
Future<void> _toConfirm(WidgetTester tester) async {
  final g = await tester.startGesture(const Offset(200, 250));
  for (var i = 0; i < 5; i++) {
    await g.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.drag(
    find.byKey(const ValueKey('map-sheet-handle')),
    const Offset(0, -300),
    warnIfMissed: false,
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.text('KLCC').first, warnIfMissed: false);
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A page with one button that opens [open]; the shot is taken with it open.
Widget _opener(Future<void> Function(BuildContext) open) => Scaffold(
  appBar: AppBar(title: const Text('Sheet host')),
  body: Center(
    child: Builder(
      builder: (c) =>
          FilledButton(onPressed: () => open(c), child: const Text('open')),
    ),
  ),
);

const _states = [
  'Johor',
  'Kedah',
  'Kelantan',
  'Melaka',
  'Negeri Sembilan',
  'Pahang',
  'Penang',
  'Perak',
  'Perlis',
  'Sabah',
  'Sarawak',
  'Selangor',
  'Terengganu',
  'Kuala Lumpur',
  'Labuan',
  'Putrajaya',
];

Widget _dropdownHost() => Scaffold(
  appBar: AppBar(title: const Text('Vehicle')),
  body: ListView(
    padding: const EdgeInsets.all(16),
    children: [
      TextFormField(
        decoration: const InputDecoration(labelText: 'Plate number'),
      ),
      const SizedBox(height: 12),
      SearchableDropdownFormField<String>(
        key: const ValueKey('state'),
        items: [
          for (final s in _states) DropdownMenuItem(value: s, child: Text(s)),
        ],
        initialValue: 'Selangor',
        decoration: const InputDecoration(labelText: 'State'),
        onChanged: (_) {},
      ),
      const SizedBox(height: 12),
      SearchableDropdownFormField<String>(
        items: [
          for (final s in _states) DropdownMenuItem(value: s, child: Text(s)),
        ],
        decoration: const InputDecoration(labelText: 'Service area'),
        hint: const Text('Choose a state'),
        onChanged: (_) {},
      ),
    ],
  ),
);

Future<void> _tapOpen(WidgetTester t) async {
  await t.tap(find.text('open'));
  await _settle(t);
}

// ---- Partner onboarding, vehicles, EV order and support fakes (from the repo's own tests).

class _FakeOnboarding extends PartnerOnboardingRepository {
  _FakeOnboarding(this.state) : super(_dbIn);
  OnboardingState state;

  @override
  Future<OnboardingState> load() async => state;

  @override
  Future<Map<String, dynamic>> patchPartner(
    OnboardingState s,
    Map<String, dynamic> patch,
  ) async => {...s.partner, ...patch};

  @override
  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> patch) async =>
      {...?state.profile, ...patch};

  @override
  Future<String> uploadAvatar(
    OnboardingState s,
    Uint8List bytes,
    String fileName,
  ) async => 'https://example.com/$fileName';
}

class _FakePeople extends PeopleRepository {
  _FakePeople({this.uploads = const []}) : super(_dbIn);
  final List<Map<String, dynamic>> uploads;

  @override
  Future<GeoOptions> geoOptions({
    Iterable<ServiceArea> inUse = const [],
  }) async => const GeoOptions(
    countries: ['Malaysia'],
    states: ['Malaysia|Selangor', 'Malaysia|Kuala Lumpur', 'Malaysia|Johor'],
    cities: [
      'Malaysia|Selangor|Ampang',
      'Malaysia|Selangor|Petaling Jaya',
      'Malaysia|Kuala Lumpur|Kuala Lumpur',
    ],
  );

  @override
  Future<List<({String id, Map<String, dynamic> values})>>
  partnerTypes() async => [
    (id: 't1', values: <String, dynamic>{'name': 'TEKSI'}),
    (id: 't2', values: <String, dynamic>{'name': 'E-HAILING'}),
  ];

  @override
  Future<List<({String id, Map<String, dynamic> values})>>
  requiredDocuments() async => [
    (id: 'licence', values: <String, dynamic>{'name': 'Driving licence'}),
    (
      id: 'ic',
      values: <String, dynamic>{'name': 'Identity card (front and back)'},
    ),
    (
      id: 'permit',
      values: <String, dynamic>{
        'name': 'Taxi permit',
        'partnerTypes': ['TEKSI'],
      },
    ),
    (
      id: 'puspakom',
      values: <String, dynamic>{
        'name': 'Puspakom inspection',
        'docTypes': ['type-vehicle'],
      },
    ),
  ];

  @override
  Future<List<({String id, Map<String, dynamic> values})>>
  documentTypes() async => [
    (id: 'type-vehicle', values: <String, dynamic>{'name': 'Vehicle'}),
  ];

  @override
  Future<List<Map<String, dynamic>>> providerDocuments(
    String partnerId,
  ) async => uploads;
}

Map<String, dynamic> _partnerRow([Map<String, dynamic> extra = const {}]) => {
  'id': 'p1',
  'auth_user_id': 'me',
  'status': 'unapproved',
  'partner_types': <String>[],
  'service_countries': <String>[],
  'service_states': <String>[],
  'service_cities': <String>[],
  'documents_ok': false,
  ...extra,
};

const _filledIn = {
  'avatar_url': 'https://example.com/a.png',
  'ic': '900101-14-5555',
  'address': 'Jalan 1, Ampang',
  'service_countries': ['Malaysia'],
  'service_states': ['Malaysia|Selangor'],
  'service_cities': ['Malaysia|Selangor|Ampang'],
  'partner_types': ['TEKSI'],
};

class _FakeVehicles extends VehicleOnboardingRepository {
  _FakeVehicles({this.existing}) : super(_dbIn);
  final Map<String, dynamic>? existing;

  @override
  Future<Map<String, dynamic>?> vehicle(String id) async => existing;

  @override
  Future<List<Map<String, dynamic>>> myVehicles(String partnerId) async => [
    ?existing,
  ];

  @override
  Future<Map<String, dynamic>> startWithPlate(
    String plate,
    Map<String, dynamic> partner,
  ) async => {
    'id': 'v1',
    'plate': plate,
    'status': 'unapproved',
    'permit': 'pending',
  };

  @override
  Future<Map<String, dynamic>> patch(
    Map<String, dynamic> v,
    Map<String, dynamic> patch,
  ) async => {...v, ...patch};

  @override
  Future<String> uploadPhoto(
    String vehicleId,
    String slot,
    Uint8List bytes,
    String fileName,
  ) async => 'https://x/$slot';
}

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

List<Override> _wizardOverrides({
  Map<String, dynamic>? partnerRow,
  Map<String, dynamic>? vehicle,
  List<Map<String, dynamic>> uploads = const [],
}) => [
  partnerOnboardingRepositoryProvider.overrideWithValue(
    _FakeOnboarding(
      OnboardingState(
        profile: {
          'id': 'me',
          'name': 'Nur Aisyah binti Rahman',
          'phone': '+60123456789',
        },
        partner: partnerRow ?? _partnerRow(),
      ),
    ),
  ),
  vehicleOnboardingRepositoryProvider.overrideWithValue(
    _FakeVehicles(existing: vehicle),
  ),
  peopleRepositoryProvider.overrideWithValue(_FakePeople(uploads: uploads)),
  liveTablesProvider.overrideWith(_QuietLive.new),
];

class _FakeEv implements EvOrderRepository {
  final List<EvOrder> stored = const [];
  final orders = <String, Map<String, dynamic>>{};
  String? active;

  @override
  Future<EvCatalog> catalog() async => EvCatalog(
    vehicles: [
      (
        id: 'jy',
        values: <String, dynamic>{
          'make': 'JUNEYAO',
          'model': 'JY AIR',
          'price': 75000,
          'taxes': jsonEncode([
            {'name': 'SST', 'amount': 7500, 'enabled': true},
          ]),
          'exteriorColors': jsonEncode([
            {'id': 'e1', 'name': 'Pearl White', 'enabled': true},
            {'id': 'e2', 'name': 'Sky Blue', 'enabled': true},
          ]),
          'interiorColors': jsonEncode([
            {'id': 'i1', 'name': 'Charcoal', 'enabled': true},
          ]),
          'accessories': jsonEncode([
            {
              'id': 'a1',
              'name': 'Wireless Charger',
              'price': 450,
              'enabled': true,
            },
          ]),
        },
      ),
    ],
    advisors: [
      (
        id: 'da1',
        values: <String, dynamic>{
          'name': 'Siti',
          'daNumber': 'DA-0001',
          'dealership': 'TEKSI KL',
        },
      ),
    ],
    financeOptions: [
      (
        id: 'cash',
        values: <String, dynamic>{
          'name': 'Full Cash',
          'type': 'Cash',
          'paymentMode': 'Full Balance',
        },
      ),
      (
        id: 'hp',
        values: <String, dynamic>{'name': 'HP 60m', 'type': 'Hire Purchase'},
      ),
    ],
    fees: [
      (
        id: 'f',
        values: <String, dynamic>{
          'country': 'Malaysia',
          'currency': 'RM',
          'amount': 3000,
          'isDefault': true,
        },
      ),
    ],
    checklist: const ['Keys handed over', 'Charging cable'],
  );

  @override
  Future<List<EvOrder>> myOrders() async => [
    ...stored,
    for (final e in orders.entries)
      (id: e.key, values: e.value, createdAt: DateTime(2026)),
  ];

  @override
  Future<EvOrder?> order(String id) async {
    final v = orders[id] ?? stored.where((o) => o.id == id).firstOrNull?.values;
    return v == null ? null : (id: id, values: v, createdAt: DateTime(2026));
  }

  @override
  Future<String> create(Map<String, dynamic> values) async {
    orders['o1'] = {...values};
    active = 'o1';
    return 'o1';
  }

  @override
  Future<Map<String, dynamic>> patch(
    String id,
    Map<String, dynamic> patch,
  ) async {
    final base =
        orders[id] ?? {...?stored.where((o) => o.id == id).firstOrNull?.values};
    return orders[id] = {...base, ...patch};
  }

  @override
  Future<String> uploadIdImage(
    String orderId,
    Uint8List bytes,
    String ext,
  ) async => 'https://x/id.$ext';

  @override
  Future<String?> activeOrderId() async => active;

  @override
  Future<void> rememberActive(String? id) async => active = id;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

SupportTicket _ticket(
  String id,
  int n,
  String subject,
  String status, {
  String last = 'We are looking into it.',
}) => SupportTicket({
  'id': id,
  'ticket_number': n,
  'subject': subject,
  'status': status,
  'created_at': '2026-10-16T09:00:00Z',
  'updated_at': '2026-10-17T10:30:00Z',
  'last_message': last,
});

SupportMessage _smsg(String id, String role, String body, int minute) =>
    SupportMessage({
      'id': id,
      'ticket_id': 't1',
      'sender_role': role,
      'sender_name': role == 'user' ? 'Nur Aisyah' : 'Agent Farah',
      'body': body,
      'message': body,
      'content': body,
      'created_at': DateTime.now()
          .subtract(Duration(minutes: 60 - minute))
          .toUtc()
          .toIso8601String(),
    });

List<Override> _supportOverrides() => [
  ticketsProvider.overrideWith(
    (ref) async => [
      _ticket('t1', 1042, 'Charged twice for my ride', 'open'),
      _ticket(
        't2',
        1017,
        'Driver did not arrive',
        'resolved',
        last: 'Refunded RM12.00 to your wallet.',
      ),
    ],
  ),
  supportMessagesProvider.overrideWith(
    (ref, id) => Stream.value([
      _smsg(
        'm1',
        'user',
        'Hi, I was charged twice for the ride to KLCC this morning.',
        0,
      ),
      _smsg(
        'm2',
        'agent',
        'Sorry about that. Can you share the booking number?',
        5,
      ),
      _smsg('m3', 'user', 'GR-1042, fare RM23.50.', 7),
      _smsg(
        'm4',
        'agent',
        'Thanks, I can see it. The duplicate charge will be refunded to your GET.wallet within 24 hours.',
        12,
      ),
    ]),
  ),
];

class _FakeTripHistory extends TripHistoryRepository {
  _FakeTripHistory(this.past) : super(_dbIn);
  final List<RideRequest> past;

  @override
  Future<List<RideRequest>> page(
    TripHistoryRole role, {
    TripHistoryFilter filter = TripHistoryFilter.all,
    DateTime? before,
    int limit = tripHistoryPageSize,
  }) async => before == null ? past : const [];
}

final _profile = Profile({
  'id': 'me',
  'display_id': 'GR-10482',
  'name': 'Nur Aisyah binti Rahman',
  'phone': '+60123456789',
  'email': 'aisyah@example.com',
  'referral_code': 'AISYAH88',
  'total_rides': 42,
  'status': 'approved',
  'nationality': 'Malaysia',
});

List<Override> _common({
  required SupabaseClient db,
  Profile? profile,
  RideRepository? rides,
  List<RideRequest> past = const [],
  Partner? partner,
  List<RideRequest> queue = const [],
  bool admin = false,
  ScheduledRidesConfig sched = ScheduledRidesConfig.off,
}) => [
  supabaseProvider.overrideWithValue(db),
  currentUserIdProvider.overrideWithValue('me'),
  tripHistoryRepositoryProvider.overrideWithValue(_FakeTripHistory(past)),
  rideRepositoryProvider.overrideWithValue(rides ?? _FakeRides()),
  geoServiceProvider.overrideWithValue(
    GeoService(client: MockClient((_) async => http.Response('', 500))),
  ),
  coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
  coinSettingsProvider.overrideWith((ref) async => null),
  serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
  rideServicesProvider.overrideWith(
    (ref) async => const [
      RideService('Ride', 'Comfortable car', 1, 4),
      RideService('Teksi', 'Metered taxi', 1.2, 4),
      RideService('XL', 'Up to 6 seats', 1.5, 6),
    ],
  ),
  recentPlacesProvider.overrideWith((ref) async => const [_eco, _klcc]),
  routeEstimateRepositoryProvider.overrideWithValue(_NoAi()),
  displaySettingsBlobProvider.overrideWith(
    (ref) async => const <String, dynamic>{},
  ),
  appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
  fareTariffsProvider.overrideWith((ref) async => const []),
  meterLaunchSessionProvider.overrideWithValue(null),
  profileProvider.overrideWith((ref) async => profile),
  partnerProvider.overrideWith((ref) async => partner),
  adminAccessProvider.overrideWith(
    (ref) async => admin
        ? const AdminAccess([AdminGrant(page: '*', edit: true)])
        : AdminAccess.none,
  ),
  scheduledRidesConfigProvider.overrideWith((ref) async => sched),
  deviceBlockedProvider.overrideWith((ref) async => false),
  pinSetProvider.overrideWith((ref) async => true),
  permissionRulesProvider.overrideWith((ref) async => PermissionRules.defaults),
  openRequestsProvider.overrideWith((ref) => Stream.value(queue)),
  partnerTypeEntriesProvider.overrideWith(
    (ref) async => [
      (
        id: 'e',
        values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false},
      ),
    ],
  ),
  assignableVehiclesProvider.overrideWith(
    (ref) async => const <AssignableVehicle>[],
  ),
  favouriteRiderIdsProvider.overrideWith((ref) async => const <String>{}),
  serviceDispatchConfigsProvider.overrideWith((ref) async => const {}),
  passkeyOfferedHereProvider.overrideWith((ref) async => false),
  myRideCodeProvider.overrideWith((ref) async => null),
  myReferrerProvider.overrideWith((ref) async => null),
  walletBalancesProvider.overrideWith(
    (ref) async => [
      WalletBalance('wallet', 128.4, 'MYR'),
      WalletBalance('coin', 1520, 'GETC'),
      WalletBalance('credit', 46.25, 'MYR'),
    ],
  ),
  walletTxProvider.overrideWith(
    (ref) async => [
      WalletTransaction({
        'id': 't1',
        'wallet_type': 'wallet',
        'kind': 'ride',
        'amount': -23.5,
        'balance_after': 128.4,
        'method': 'wallet',
        'created_at': '2026-10-17T08:48:00Z',
        'description': 'Ride to KLCC',
      }),
      WalletTransaction({
        'id': 't2',
        'wallet_type': 'coin',
        'kind': 'reward',
        'amount': 20,
        'balance_after': 1520,
        'created_at': '2026-10-17T08:49:00Z',
        'description': 'Ride reward',
      }),
      WalletTransaction({
        'id': 't3',
        'wallet_type': 'wallet',
        'kind': 'reload',
        'amount': 100,
        'balance_after': 151.9,
        'method': 'fpx',
        'created_at': '2026-10-15T12:00:00Z',
        'description': 'Reload via FPX',
      }),
    ],
  ),
];

final _log = StringBuffer();
final _audit = StringBuffer();

Future<void> _loadFonts() async {
  const dir = '/opt/flutter/bin/cache/artifacts/material_fonts';
  const families = [
    'Roboto',
    'monospace',
    '.SF UI Text',
    '.SF UI Display',
    '.SF Pro Text',
    '.SF Pro Display',
    '.AppleSystemUIFont',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
  ];
  for (final family in families) {
    final loader = FontLoader(family);
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
      'Roboto-Light.ttf',
      'Roboto-Italic.ttf',
    ]) {
      final file = File('$dir/$f');
      if (!file.existsSync()) continue;
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
    }
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons');
  icons.addFont(
    Future.value(
      ByteData.sublistView(
        File('$dir/MaterialIcons-Regular.otf').readAsBytesSync(),
      ),
    ),
  );
  await icons.load();
}

ThemeData _theme(Brightness b) {
  final t = appTheme(b);
  final style = t.filledButtonTheme.style!;
  return t.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: style.copyWith(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: 'Roboto',
          ),
        ),
      ),
    ),
  );
}

double _frameW = _w,
    _frameTop = _top,
    _frameBottom = _bottom,
    _frameKeyboard = 0;
bool _frameSe = false;

Widget _frame(Widget app, {required bool dark}) => RepaintBoundary(
  key: const Key('frame'),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      children: [
        app,
        // The unsafe zones, tinted so content under them shows up.
        if (Platform.environment['AUDIT'] != '1')
          IgnorePointer(
            child: Column(
              children: [
                SizedBox(
                  height: _frameTop,
                  width: double.infinity,
                  child: const ColoredBox(color: Color(0x33FF0000)),
                ),
                const Spacer(),
                SizedBox(
                  height: _frameBottom,
                  width: double.infinity,
                  child: const ColoredBox(color: Color(0x33FF0000)),
                ),
              ],
            ),
          ),
        if (_frameKeyboard > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _frameKeyboard,
            child: const ColoredBox(
              color: Color(0xFFD1D5DB),
              child: Center(
                child: Text(
                  'keyboard',
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    color: Color(0xFF6B7280),
                    fontSize: 24,
                  ),
                ),
              ),
            ),
          ),
        // The Dynamic Island and the home indicator.
        if (!_frameSe)
          Positioned(
            top: 11,
            left: (_frameW - 126) / 2,
            child: Container(
              width: 126,
              height: 37,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        if (!_frameSe)
          Positioned(
            bottom: 8,
            left: (_frameW - 140) / 2,
            child: Container(
              width: 140,
              height: 5,
              decoration: BoxDecoration(
                color: dark ? Colors.white70 : Colors.black87,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    ),
  ),
);

/// A device frame: logical size, scale, and the unsafe strips.
typedef _Device = ({
  double w,
  double h,
  double dpr,
  double top,
  double bottom,
  bool island,
});

const _iphone15 = (
  w: 393.0,
  h: 852.0,
  dpr: 3.0,
  top: 59.0,
  bottom: 34.0,
  island: true,
);
const _iphoneSe = (
  w: 375.0,
  h: 667.0,
  dpr: 2.0,
  top: 20.0,
  bottom: 0.0,
  island: false,
);
const _iphone15Land = (
  w: 852.0,
  h: 393.0,
  dpr: 3.0,
  top: 0.0,
  bottom: 21.0,
  island: false,
);
const _ipad = (
  w: 820.0,
  h: 1180.0,
  dpr: 2.0,
  top: 24.0,
  bottom: 20.0,
  island: false,
);
const _ipadLand = (
  w: 1180.0,
  h: 820.0,
  dpr: 2.0,
  top: 24.0,
  bottom: 20.0,
  island: false,
);
// iPad Slide Over / narrow Split View: 320 pt wide, full height.
const _slideOver = (
  w: 320.0,
  h: 1136.0,
  dpr: 2.0,
  top: 0.0,
  bottom: 20.0,
  island: false,
);

/// Renders the app at [route] (through the real router, bottom bar and side
/// menu), or [screen] on its own, in an iPhone frame and writes `<name>.png`.
Future<void> _shot(
  WidgetTester tester,
  String name, {
  String? route,
  Widget? screen,
  bool signedIn = true,
  List<Override> overrides = const [],
  Profile? profile,
  RideRepository? rides,
  List<RideRequest> past = const [],
  Partner? partner,
  List<RideRequest> queue = const [],
  bool admin = false,
  ScheduledRidesConfig sched = ScheduledRidesConfig.off,
  bool dark = false,
  double textScale = 1.0,
  bool keyboard = false,
  bool se = false,
  _Device? device,
  int frames = 12,
  Duration step = const Duration(milliseconds: 100),
  Future<void> Function(WidgetTester)? act,
}) async {
  // Sweeps: DARK=1, XL=1 (text scale 1.3), SE=1, LAND=1, BOLD=1 (iOS Bold Text) force
  // the setting on every screenshot.
  final env = Platform.environment;
  if (env['DARK'] == '1') dark = true;
  if (env['XL'] == '1') textScale = 1.35;
  if (env['SE'] == '1' && device == null) se = true;
  // LAND=1 renders every phone screenshot in iPhone 15 landscape (allowed by
  // Info.plist for every screen).
  if (env['LAND'] == '1' && device == null) device = _iphone15Land;
  SharedPreferences.setMockInitialValues({});
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  if (env['BOLD'] == '1') {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(boldText: true);
  }
  // iPhone SE (3rd gen): 375 x 667 at 2x, 20 pt status bar, no home indicator.
  final d = device ?? (se ? _iphoneSe : _iphone15);
  final w = d.w, h = d.h, dpr = d.dpr, top = d.top, bottom = d.bottom;
  _frameW = w;
  _frameTop = top;
  _frameBottom = bottom;
  _frameSe = !d.island;
  tester.view.physicalSize = Size(w * dpr, h * dpr);
  tester.view.devicePixelRatio = dpr;
  // With the keyboard up, iOS reports no bottom padding (viewPadding keeps it).
  tester.view.padding = FakeViewPadding(
    top: top * dpr,
    bottom: keyboard ? 0 : bottom * dpr,
  );
  tester.view.viewPadding = FakeViewPadding(
    top: top * dpr,
    bottom: bottom * dpr,
  );
  // The iOS keyboard (336 pt on an iPhone 15, 260 on an SE) is up.
  _frameKeyboard = keyboard
      ? (w > h
            ? 200.0
            : se
            ? 260.0
            : 336.0)
      : 0;
  if (keyboard)
    tester.view.viewInsets = FakeViewPadding(bottom: _frameKeyboard * dpr);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.platformBrightnessTestValue = dark
      ? Brightness.dark
      : Brightness.light;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
  final errors = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (d) {
    final s = d.exceptionAsString();
    if (!errors.contains(s)) errors.add('${d.library}: $s');
    prev?.call(d);
  };
  final container = ProviderContainer(
    overrides: [
      ..._common(
        db: signedIn ? _dbIn : _dbOut,
        profile: profile ?? _profile,
        rides: rides,
        past: past,
        partner: partner,
        queue: queue,
        admin: admin,
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  Widget clamp(Widget? child) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: maxAppTextScale,
    child: child!,
  );
  try {
    final Widget app;
    if (route != null) {
      final router = container.read(routerProvider);
      app = MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        routerConfig: router,
        builder: (_, child) => clamp(child),
      );
      await tester.pumpWidget(
        _frame(
          UncontrolledProviderScope(container: container, child: app),
          dark: dark,
        ),
      );
      await tester.pump();
      router.go(route);
    } else {
      app = MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: screen,
        builder: (_, child) => clamp(child),
      );
      await tester.pumpWidget(
        _frame(
          UncontrolledProviderScope(container: container, child: app),
          dark: dark,
        ),
      );
    }
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
    if (act != null) await act(tester);
    await expectLater(
      find.byKey(const Key('frame')),
      matchesGoldenFile(Uri.file('$_outDir/$name.png')),
    );
    if (Platform.environment['AUDIT'] == '1') {
      final handle = tester.ensureSemantics();
      await tester.pump();
      for (final g in [
        iOSTapTargetGuideline,
        labeledTapTargetGuideline,
        textContrastGuideline,
      ]) {
        final r = await g.evaluate(tester);
        if (!r.passed) {
          _audit.writeln('== $name :: ${g.description}');
          _audit.writeln(r.reason);
        }
      }
      handle.dispose();
    }
  } catch (e) {
    errors.add('TEST ERROR: $e');
  } finally {
    debugDefaultTargetPlatformOverride = null;
    FlutterError.onError = prev;
    final ex = tester.takeException();
    if (ex != null) errors.add(ex.toString());
    _log.writeln('== $name${errors.isEmpty ? ' OK' : ''}');
    for (final e in errors) {
      _log.writeln('  ! ${e.split('\n').take(3).join(' | ')}');
    }
    File('$_outDir/log.txt').writeAsStringSync(_log.toString());
    if (_audit.isNotEmpty)
      File('$_outDir/audit.txt').writeAsStringSync(_audit.toString());
  }
}

Future<void> _probe(
  String name,
  Future<Object?> Function(ProviderContainer c) read,
) async {
  final c = ProviderContainer(
    overrides: _common(db: _dbIn, profile: _profile),
  );
  try {
    final v = await read(c);
    // ignore: avoid_print
    print('PROBE $name -> OK ${v.runtimeType}');
  } catch (e, st) {
    // ignore: avoid_print
    print(
      'PROBE $name -> $e\n${st.toString().split('\n').take(12).join('\n')}',
    );
  } finally {
    c.dispose();
  }
}

void main() {
  // Not a regression test: it only runs where a reviewer asked for pictures.
  if (Platform.environment['SHOTS_DIR'] == null) {
    test('skipped: set SHOTS_DIR to render the iPhone screenshots', () {});
    return;
  }
  if (Platform.environment['PROBE'] == '1') {
    test('probe', () async {
      await _signIn();
      await _probe(
        'emergencyContacts',
        (c) => c.read(emergencyContactsProvider.future),
      );
    });
    return;
  }
  setUpAll(() async {
    Directory(_outDir).createSync(recursive: true);
    await _loadFonts();
    await _signIn();
  });

  group('auth', () {
    testWidgets(
      'welcome',
      (t) => _shot(t, 'auth_welcome', route: '/login', signedIn: false),
    );
    testWidgets(
      'welcome dark',
      (t) => _shot(
        t,
        'auth_welcome_dark',
        route: '/login',
        signedIn: false,
        dark: true,
      ),
    );
    testWidgets(
      'phone',
      (t) => _shot(t, 'auth_phone', route: '/login/phone', signedIn: false),
    );
    testWidgets(
      'phone large text',
      (t) => _shot(
        t,
        'auth_phone_xl',
        route: '/login/phone',
        signedIn: false,
        textScale: 1.35,
      ),
    );
    testWidgets(
      'phone typing',
      (t) => _shot(
        t,
        'auth_phone_typed',
        route: '/login/phone',
        signedIn: false,
        act: (t) async {
          await t.tap(find.byType(TextField).first);
          await t.pump();
          await t.enterText(find.byType(TextField).first, '123456789');
          await t.pump(const Duration(milliseconds: 300));
        },
      ),
    );
    testWidgets(
      'otp',
      (t) => _shot(
        t,
        'auth_otp',
        route: '/login/otp?phone=%2B60123456789',
        signedIn: false,
      ),
    );
    testWidgets(
      'pin',
      (t) => _shot(
        t,
        'auth_pin',
        route: '/login/pin?phone=%2B60123456789',
        signedIn: false,
      ),
    );
    testWidgets(
      'pin dark',
      (t) => _shot(
        t,
        'auth_pin_dark',
        route: '/login/pin?phone=%2B60123456789',
        signedIn: false,
        dark: true,
      ),
    );
    testWidgets(
      'closed',
      (t) => _shot(
        t,
        'auth_closed',
        route: '/login/closed?phone=%2B60123456789',
        signedIn: false,
      ),
    );
    testWidgets(
      'set pin',
      (t) => _shot(t, 'auth_set_pin', screen: const SetPinScreen()),
    );
    testWidgets(
      'set pin large text',
      (t) => _shot(
        t,
        'auth_set_pin_xl',
        screen: const SetPinScreen(),
        textScale: 1.35,
      ),
    );
  });

  group('rider', () {
    testWidgets('home', (t) => _shot(t, 'home', route: '/'));
    testWidgets(
      'home dark',
      (t) => _shot(t, 'home_dark', route: '/', dark: true),
    );
    testWidgets(
      'home large text',
      (t) => _shot(t, 'home_xl', route: '/', textScale: 1.35),
    );
    testWidgets(
      'home menu open',
      (t) => _shot(
        t,
        'home_menu',
        route: '/',
        act: (t) async {
          await t.tap(find.byKey(const ValueKey('home-menu')));
          for (var i = 0; i < 10; i++) {
            await t.pump(const Duration(milliseconds: 100));
          }
        },
      ),
    );
    testWidgets(
      'home search tapped',
      (t) => _shot(
        t,
        'home_search',
        route: '/',
        act: (t) async {
          await t.tap(find.text('Where to & for how much?'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 500));
          await t.pump(const Duration(milliseconds: 500));
        },
      ),
    );
    testWidgets(
      'home with ongoing ride',
      (t) => _shot(
        t,
        'home_ongoing',
        route: '/',
        rides: _FakeRides(ongoing: _ride('r1', 'open')),
      ),
    );
    testWidgets('trips', (t) => _shot(t, 'trips', route: '/trips'));
    testWidgets(
      'trips with history',
      (t) => _shot(
        t,
        'trips_history',
        route: '/trips',
        past: [
          _ride('r1', 'completed'),
          _ride('r2', 'cancelled', fare: 12),
          _ride(
            'r3',
            'completed',
            fare: 48.9,
            from: 'KLIA2',
            to: 'Bangsar South',
          ),
        ],
      ),
    );
    testWidgets(
      'trips with history dark',
      (t) => _shot(
        t,
        'trips_history_dark',
        route: '/trips',
        dark: true,
        past: [_ride('r1', 'completed'), _ride('r2', 'cancelled', fare: 12)],
      ),
    );
    testWidgets(
      'trips scheduled',
      (t) => _shot(t, 'trips_scheduled', route: '/trips/scheduled'),
    );
    testWidgets('wallet', (t) => _shot(t, 'wallet', route: '/wallet'));
    testWidgets(
      'wallet dark',
      (t) => _shot(t, 'wallet_dark', route: '/wallet', dark: true),
    );
    testWidgets(
      'wallet large text',
      (t) => _shot(t, 'wallet_xl', route: '/wallet', textScale: 1.35),
    );
    testWidgets(
      'wallet history',
      (t) => _shot(t, 'wallet_history', route: '/wallet/history'),
    );
    testWidgets(
      'wallet trade',
      (t) => _shot(t, 'wallet_trade', route: '/wallet/trade'),
    );
    testWidgets(
      'wallet receive',
      (t) => _shot(t, 'wallet_receive', route: '/wallet/receive'),
    );
    testWidgets('account', (t) => _shot(t, 'account', route: '/account'));
    testWidgets(
      'account dark',
      (t) => _shot(t, 'account_dark', route: '/account', dark: true),
    );
    testWidgets(
      'account large text',
      (t) => _shot(t, 'account_xl', route: '/account', textScale: 1.35),
    );
    testWidgets(
      'profile',
      (t) => _shot(t, 'profile', route: '/account/profile'),
    );
    testWidgets(
      'edit profile',
      (t) => _shot(t, 'profile_edit', route: '/account/edit'),
    );
    testWidgets(
      'notifications',
      (t) => _shot(t, 'notifications', route: '/account/notifications'),
    );
    testWidgets(
      'referral',
      (t) => _shot(t, 'referral', route: '/account/referral'),
    );
    testWidgets(
      'my ride',
      (t) => _shot(t, 'my_ride', route: '/account/my-ride'),
    );
    testWidgets('my qr', (t) => _shot(t, 'my_qr', route: '/account/my-qr'));
    testWidgets('safety', (t) => _shot(t, 'safety', route: '/account/safety'));
    testWidgets(
      'emergency contacts',
      (t) => _shot(t, 'emergency', route: '/account/emergency'),
    );
    testWidgets(
      'user guide',
      (t) => _shot(t, 'guide', route: '/account/guide'),
    );
    testWidgets(
      'help assistant',
      (t) => _shot(t, 'help', route: '/account/help'),
    );
    testWidgets(
      'settings',
      (t) => _shot(t, 'settings', route: '/account/settings'),
    );
    testWidgets(
      'settings dark',
      (t) => _shot(t, 'settings_dark', route: '/account/settings', dark: true),
    );
    testWidgets(
      'settings large text',
      (t) =>
          _shot(t, 'settings_xl', route: '/account/settings', textScale: 1.35),
    );
    testWidgets(
      'change phone',
      (t) => _shot(t, 'settings_phone', route: '/account/settings/phone'),
    );
    testWidgets(
      'change pin',
      (t) => _shot(t, 'settings_pin', route: '/account/settings/pin'),
    );
    testWidgets(
      'passkeys',
      (t) => _shot(t, 'settings_passkeys', route: '/account/settings/passkeys'),
    );
    testWidgets('ev order', (t) => _shot(t, 'ev', route: '/ev'));
    testWidgets(
      'diagnostics',
      (t) => _shot(t, 'diagnostics', route: '/diagnostics'),
    );
  });

  group('booking', () {
    for (final (suffix, dark, scale, se) in [
      ('', false, 1.0, false),
      ('_dark', true, 1.0, false),
      ('_xl', false, 1.35, false),
      ('_se', false, 1.0, true),
    ]) {
      testWidgets(
        'confirm$suffix',
        (t) => _shot(
          t,
          'book_confirm$suffix',
          route: '/',
          rides: _BookingRides(),
          dark: dark,
          textScale: scale,
          se: se,
          act: _toConfirm,
        ),
      );
    }
    testWidgets(
      'fare info',
      (t) => _shot(
        t,
        'book_fare_info',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await t.tap(
            find.byKey(const ValueKey('vehicle-info-Ride')),
            warnIfMissed: false,
          );
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'fare details',
      (t) => _shot(
        t,
        'book_fare_details',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await t.tap(
            find.byKey(const ValueKey('fare-details')),
            warnIfMissed: false,
          );
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'add stop',
      (t) => _shot(
        t,
        'book_add_stop',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await t.tap(
            find.byKey(const ValueKey('confirm-add-stop')),
            warnIfMissed: false,
          );
          await _settle(t);
        },
      ),
    );
    testWidgets('home SE', (t) => _shot(t, 'home_se', route: '/', se: true));
    testWidgets(
      'home search SE',
      (t) => _shot(
        t,
        'home_search_se',
        route: '/',
        se: true,
        keyboard: true,
        act: (t) async {
          await t.tap(find.text('Where to & for how much?'));
          await _settle(t, 10);
        },
      ),
    );
  });

  group('tracking', () {
    for (final status in ['open', 'accepted', 'arrived', 'on_trip']) {
      testWidgets(
        'ride $status',
        (t) => _shot(
          t,
          'ride_$status',
          route: '/ride/r1',
          overrides: _trackingOverrides(_tracked(status)),
        ),
      );
    }
    testWidgets(
      'ride accepted dark',
      (t) => _shot(
        t,
        'ride_accepted_dark',
        route: '/ride/r1',
        dark: true,
        overrides: _trackingOverrides(_tracked('accepted')),
      ),
    );
    testWidgets(
      'ride accepted large text',
      (t) => _shot(
        t,
        'ride_accepted_xl',
        route: '/ride/r1',
        textScale: 1.35,
        overrides: _trackingOverrides(_tracked('accepted')),
      ),
    );
    testWidgets(
      'ride accepted SE',
      (t) => _shot(
        t,
        'ride_accepted_se',
        route: '/ride/r1',
        se: true,
        overrides: _trackingOverrides(_tracked('accepted')),
      ),
    );
    testWidgets(
      'ride completed, payment due',
      (t) => _shot(
        t,
        'ride_completed_due',
        route: '/ride/r1',
        overrides: _trackingOverrides(
          _tracked('completed', extra: {'payment_status': 'due'}),
        ),
      ),
    );
    testWidgets(
      'ride completed, paid',
      (t) => _shot(
        t,
        'ride_completed_paid',
        route: '/ride/r1',
        overrides: _trackingOverrides(
          _tracked(
            'completed',
            extra: {
              'payment_status': 'paid',
              'paid_method': 'cash',
              'paid_amount': 23.5,
            },
          ),
        ),
      ),
    );
    testWidgets(
      'ride cancelled',
      (t) => _shot(
        t,
        'ride_cancelled',
        route: '/ride/r1',
        overrides: _trackingOverrides(
          _tracked(
            'cancelled',
            extra: {'cancel_reason': 'Driver took too long'},
          ),
        ),
      ),
    );
    testWidgets(
      'receipt',
      (t) => _shot(
        t,
        'trip_receipt',
        route: '/trips/r1',
        past: [_tracked('completed')],
        overrides: _trackingOverrides(_tracked('completed')),
      ),
    );
    testWidgets(
      'chat',
      (t) => _shot(
        t,
        'ride_chat',
        route: '/ride/r1/chat',
        keyboard: true,
        overrides: _trackingOverrides(_tracked('accepted')),
      ),
    );
  });

  group('driver', () {
    final queue = [
      _request('q1', 'Pavilion KL', 'Mont Kiara', 18.5, km: 7.2),
      _request('q2', 'Bangsar Village', 'KL Sentral', 9, km: 3.1),
    ];
    testWidgets(
      'offline',
      (t) => _shot(
        t,
        'drive_offline',
        route: '/drive',
        partner: _approved,
        queue: queue,
      ),
    );
    testWidgets(
      'offline dark',
      (t) => _shot(
        t,
        'drive_offline_dark',
        route: '/drive',
        dark: true,
        partner: _approved,
        queue: queue,
      ),
    );
    testWidgets(
      'online with queue',
      (t) => _shot(
        t,
        'drive_online',
        route: '/drive',
        partner: _approved,
        queue: queue,
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
        },
      ),
    );
    testWidgets(
      'online large text',
      (t) => _shot(
        t,
        'drive_online_xl',
        route: '/drive',
        textScale: 1.35,
        partner: _approved,
        queue: queue,
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
        },
      ),
    );
    testWidgets(
      'online SE',
      (t) => _shot(
        t,
        'drive_online_se',
        route: '/drive',
        se: true,
        partner: _approved,
        queue: queue,
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
        },
      ),
    );
    testWidgets(
      'queue raised',
      (t) => _shot(
        t,
        'drive_online_up',
        route: '/drive',
        partner: _approved,
        queue: queue,
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
          await t.drag(
            find.byKey(const ValueKey('map-sheet-handle')),
            const Offset(0, -500),
            warnIfMissed: false,
          );
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'request opened',
      (t) => _shot(
        t,
        'drive_request',
        route: '/drive',
        partner: _approved,
        queue: queue,
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
          await t.drag(
            find.byKey(const ValueKey('map-sheet-handle')),
            const Offset(0, -500),
            warnIfMissed: false,
          );
          await _settle(t);
          await t.tap(find.text('Pavilion KL').first, warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    for (final status in ['accepted', 'arrived', 'on_trip']) {
      testWidgets(
        'trip $status',
        (t) => _shot(
          t,
          'drive_trip_$status',
          route: '/drive/trip/r1',
          partner: _approved,
          overrides: [..._trackingOverrides(_driving(status))],
        ),
      );
    }
    testWidgets(
      'trip completed, payment due',
      (t) => _shot(
        t,
        'drive_trip_completed_due',
        route: '/drive/trip/r1',
        partner: _approved,
        overrides: [
          ..._trackingOverrides(
            _driving('completed', extra: {'payment_status': 'due'}),
          ),
        ],
      ),
    );
    testWidgets(
      'trip arrived dark',
      (t) => _shot(
        t,
        'drive_trip_arrived_dark',
        route: '/drive/trip/r1',
        dark: true,
        partner: _approved,
        overrides: [..._trackingOverrides(_driving('arrived'))],
      ),
    );
    testWidgets(
      'trip arrived large text',
      (t) => _shot(
        t,
        'drive_trip_arrived_xl',
        route: '/drive/trip/r1',
        textScale: 1.35,
        partner: _approved,
        overrides: [..._trackingOverrides(_driving('arrived'))],
      ),
    );
  });

  group('keyboard', () {
    testWidgets(
      'phone typing',
      (t) => _shot(
        t,
        'kb_phone',
        route: '/login/phone',
        signedIn: false,
        keyboard: true,
        act: (t) async {
          await t.tap(find.byType(TextField).first);
          await t.enterText(find.byType(TextField).first, '123456789');
          await _settle(t, 3);
        },
      ),
    );
    testWidgets(
      'phone typing SE',
      (t) => _shot(
        t,
        'kb_phone_se',
        route: '/login/phone',
        signedIn: false,
        keyboard: true,
        se: true,
      ),
    );
    testWidgets(
      'otp',
      (t) => _shot(
        t,
        'kb_otp',
        route: '/login/otp?phone=%2B60123456789',
        signedIn: false,
        keyboard: true,
      ),
    );
    testWidgets(
      'otp SE',
      (t) => _shot(
        t,
        'kb_otp_se',
        route: '/login/otp?phone=%2B60123456789',
        signedIn: false,
        keyboard: true,
        se: true,
      ),
    );
    testWidgets(
      'set pin',
      (t) =>
          _shot(t, 'kb_set_pin', screen: const SetPinScreen(), keyboard: true),
    );
    testWidgets(
      'set pin SE large text',
      (t) => _shot(
        t,
        'kb_set_pin_se_xl',
        screen: const SetPinScreen(),
        keyboard: true,
        se: true,
        textScale: 1.35,
      ),
    );
    testWidgets(
      'help composer',
      (t) => _shot(
        t,
        'kb_help',
        route: '/account/help',
        keyboard: true,
        act: (t) async {
          await t.tap(find.byType(TextField).first);
          await t.enterText(
            find.byType(TextField).first,
            'How do I pay with GET.coin?',
          );
          await _settle(t, 3);
        },
      ),
    );
    testWidgets(
      'edit profile',
      (t) => _shot(
        t,
        'kb_profile_edit',
        route: '/account/edit',
        keyboard: true,
        act: (t) async {
          await t.tap(find.byType(TextField).last, warnIfMissed: false);
          await _settle(t, 3);
        },
      ),
    );
    testWidgets(
      'change phone SE',
      (t) => _shot(
        t,
        'kb_change_phone_se',
        route: '/account/settings/phone',
        keyboard: true,
        se: true,
      ),
    );
  });

  group('sheets', () {
    testWidgets(
      'pickup time',
      (t) => _shot(
        t,
        'sheet_pickup_time',
        screen: _opener(
          (c) =>
              showPickupTimeSheet(c, const ScheduledRidesConfig(enabled: true)),
        ),
        act: _tapOpen,
      ),
    );
    testWidgets(
      'book for',
      (t) => _shot(
        t,
        'sheet_book_for',
        screen: _opener((c) => showBookForSheet(c)),
        act: _tapOpen,
      ),
    );
    testWidgets(
      'book for keyboard',
      (t) => _shot(
        t,
        'sheet_book_for_kb',
        keyboard: true,
        screen: _opener((c) => showBookForSheet(c)),
        act: _tapOpen,
      ),
    );
    testWidgets(
      'payment',
      (t) => _shot(
        t,
        'sheet_payment',
        screen: _opener((c) => showPaymentSheet(c, 'Cash')),
        act: _tapOpen,
      ),
    );
    testWidgets(
      'payment dark',
      (t) => _shot(
        t,
        'sheet_payment_dark',
        dark: true,
        screen: _opener((c) => showPaymentSheet(c, 'Cash')),
        act: _tapOpen,
      ),
    );
    testWidgets(
      'search cancel',
      (t) => _shot(
        t,
        'sheet_search_cancel',
        screen: _opener((c) => showSearchCancelSheet(c)),
        act: _tapOpen,
      ),
    );
    testWidgets(
      'location share',
      (t) => _shot(
        t,
        'sheet_location_share',
        screen: _opener((c) => showLocationShareSheet(c, on: true)),
        act: _tapOpen,
      ),
    );
    testWidgets(
      'welcome SE',
      (t) => _shot(
        t,
        'auth_welcome_se',
        route: '/login',
        signedIn: false,
        se: true,
      ),
    );
    testWidgets(
      'wallet SE',
      (t) => _shot(t, 'wallet_se', route: '/wallet', se: true),
    );
    testWidgets(
      'settings SE large text',
      (t) => _shot(
        t,
        'settings_se_xl',
        route: '/account/settings',
        se: true,
        textScale: 1.35,
      ),
    );
    testWidgets(
      'account SE',
      (t) => _shot(t, 'account_se', route: '/account', se: true),
    );
  });

  group('admin', () {
    for (final r in [
      'dashboard',
      'users',
      'partners',
      'vehicles',
      'documents',
      'rides',
      'support',
      'push',
      'commission',
      'fare-tariffs',
      'messaging',
      'sub-admins',
      'settings',
    ]) {
      testWidgets(
        r,
        (t) => _shot(t, 'admin_$r', route: '/admin/$r', admin: true),
      );
    }
    testWidgets(
      'dashboard dark',
      (t) => _shot(
        t,
        'admin_dashboard_dark',
        route: '/admin/dashboard',
        admin: true,
        dark: true,
      ),
    );
    testWidgets(
      'users large text',
      (t) => _shot(
        t,
        'admin_users_xl',
        route: '/admin/users',
        admin: true,
        textScale: 1.35,
      ),
    );
    testWidgets(
      'rides SE',
      (t) => _shot(
        t,
        'admin_rides_se',
        route: '/admin/rides',
        admin: true,
        se: true,
      ),
    );
    testWidgets(
      'drawer',
      (t) => _shot(
        t,
        'admin_drawer',
        route: '/admin/dashboard',
        admin: true,
        act: (t) async {
          final s = find
              .byType(Scaffold)
              .evaluate()
              .map((e) => e.widget as Scaffold)
              .where((w) => w.drawer != null);
          if (s.isNotEmpty) {
            final state = t.state<ScaffoldState>(find.byWidget(s.first));
            state.openDrawer();
            await _settle(t);
          }
        },
      ),
    );
    for (final m in [
      'display',
      'maps',
      'meter-digital',
      'page-settings',
      'required-documents',
      'vehicle-services',
      'country-states-cities',
      'airport-areas',
      'partner-type',
      'payment-gateway',
      'ev-orders',
      'session-history',
      'app-release',
      'site',
      'splash',
    ]) {
      testWidgets(
        'm $m',
        (t) => _shot(
          t,
          'admin_m_${m.replaceAll('-', '_')}',
          route: '/admin/m/$m',
          admin: true,
        ),
      );
    }
    testWidgets(
      'settings category',
      (t) => _shot(
        t,
        'admin_settings_vehicle_type',
        route: '/admin/settings/vehicle-type',
        admin: true,
      ),
    );
    testWidgets(
      'account with admin row',
      (t) => _shot(t, 'account_admin', route: '/account', admin: true),
    );
  });

  group('picker', () {
    testWidgets(
      'dropdown closed',
      (t) => _shot(t, 'picker_closed', screen: _dropdownHost()),
    );
    testWidgets(
      'dropdown open',
      (t) => _shot(
        t,
        'picker_open',
        screen: _dropdownHost(),
        keyboard: true,
        act: (t) async {
          await t.tap(find.byKey(const ValueKey('state')));
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'dropdown searching',
      (t) => _shot(
        t,
        'picker_search',
        screen: _dropdownHost(),
        keyboard: true,
        act: (t) async {
          await t.tap(find.byKey(const ValueKey('state')));
          await _settle(t);
          await t.enterText(
            find.byKey(const ValueKey('search-select-field')),
            'sel',
          );
          await _settle(t, 3);
        },
      ),
    );
    testWidgets(
      'dropdown open SE large text',
      (t) => _shot(
        t,
        'picker_open_se_xl',
        screen: _dropdownHost(),
        keyboard: true,
        se: true,
        textScale: 1.35,
        act: (t) async {
          await t.tap(find.byKey(const ValueKey('state')));
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'dropdown open dark',
      (t) => _shot(
        t,
        'picker_open_dark',
        screen: _dropdownHost(),
        keyboard: true,
        dark: true,
        act: (t) async {
          await t.tap(find.byKey(const ValueKey('state')));
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'search picker',
      (t) => _shot(
        t,
        'picker_dialog',
        keyboard: true,
        screen: _opener(
          (c) => showSearchPicker<String>(
            c,
            title: 'Choose a service',
            selected: 'Teksi',
            choices: [
              for (final s in [
                'Ride',
                'Teksi',
                'XL',
                'Premium',
                'Van',
                'Bike',
                'Freight',
                'Airport',
                'Hourly',
                'Pet friendly',
              ])
                (
                  value: s,
                  label: s,
                  subtitle: 'Up to 4 passengers',
                  leading: const Icon(Icons.local_taxi),
                ),
            ],
          ),
        ),
        act: _tapOpen,
      ),
    );
  });

  group('wizards', () {
    testWidgets(
      'onboarding start',
      (t) => _shot(
        t,
        'wiz_onboarding_start',
        route: '/drive/onboarding',
        overrides: _wizardOverrides(),
      ),
    );
    testWidgets(
      'onboarding start large text',
      (t) => _shot(
        t,
        'wiz_onboarding_start_xl',
        route: '/drive/onboarding',
        textScale: 1.35,
        overrides: _wizardOverrides(),
      ),
    );
    testWidgets(
      'onboarding documents',
      (t) => _shot(
        t,
        'wiz_onboarding_docs',
        route: '/drive/onboarding',
        overrides: _wizardOverrides(partnerRow: _partnerRow(_filledIn)),
      ),
    );
    testWidgets(
      'onboarding documents dark',
      (t) => _shot(
        t,
        'wiz_onboarding_docs_dark',
        route: '/drive/onboarding',
        dark: true,
        overrides: _wizardOverrides(partnerRow: _partnerRow(_filledIn)),
      ),
    );
    testWidgets(
      'onboarding documents SE',
      (t) => _shot(
        t,
        'wiz_onboarding_docs_se',
        route: '/drive/onboarding',
        se: true,
        overrides: _wizardOverrides(partnerRow: _partnerRow(_filledIn)),
      ),
    );
    testWidgets(
      'onboarding submitted',
      (t) => _shot(
        t,
        'wiz_onboarding_submitted',
        route: '/drive/onboarding',
        overrides: _wizardOverrides(
          partnerRow: _partnerRow({
            ..._filledIn,
            'documents_ok': true,
            'status': 'pending',
          }),
          uploads: [
            {
              'id': 'd1',
              'document_id': 'licence',
              'status': 'pending',
              'front_url': 'https://x/f.jpg',
            },
            {
              'id': 'd2',
              'document_id': 'ic',
              'status': 'approved',
              'front_url': 'https://x/f.jpg',
            },
            {
              'id': 'd3',
              'document_id': 'permit',
              'status': 'rejected',
              'front_url': 'https://x/f.jpg',
              'notes': 'Blurry photo',
            },
          ],
        ),
      ),
    );
    testWidgets(
      'vehicles list',
      (t) => _shot(
        t,
        'wiz_vehicles',
        route: '/drive/vehicles',
        partner: _approved,
        overrides: _wizardOverrides(
          partnerRow: _partnerRow({..._filledIn, 'status': 'approved'}),
          vehicle: {
            'id': 'v1',
            'plate': 'WXY 1234',
            'make': 'Perodua',
            'model': 'Bezza',
            'year': 2022,
            'color': 'Silver',
            'status': 'unapproved',
            'permit': 'pending',
          },
        ),
      ),
    );
    testWidgets(
      'vehicle new',
      (t) => _shot(
        t,
        'wiz_vehicle_new',
        route: '/drive/vehicles/new',
        partner: _approved,
        overrides: _wizardOverrides(
          partnerRow: _partnerRow({..._filledIn, 'status': 'approved'}),
        ),
      ),
    );
    testWidgets(
      'vehicle new keyboard',
      (t) => _shot(
        t,
        'wiz_vehicle_new_kb',
        route: '/drive/vehicles/new',
        partner: _approved,
        keyboard: true,
        overrides: _wizardOverrides(
          partnerRow: _partnerRow({..._filledIn, 'status': 'approved'}),
        ),
        act: (t) async {
          await t.tap(find.byType(TextField).first, warnIfMissed: false);
          await _settle(t, 3);
        },
      ),
    );
    testWidgets(
      'vehicle resume',
      (t) => _shot(
        t,
        'wiz_vehicle_resume',
        route: '/drive/vehicles/v1',
        partner: _approved,
        overrides: _wizardOverrides(
          partnerRow: _partnerRow({..._filledIn, 'status': 'approved'}),
          vehicle: {
            'id': 'v1',
            'plate': 'WXY 1234',
            'status': 'unapproved',
            'permit': 'pending',
          },
        ),
      ),
    );
    testWidgets(
      'ev order',
      (t) => _shot(
        t,
        'wiz_ev',
        route: '/ev',
        overrides: [evOrderRepositoryProvider.overrideWithValue(_FakeEv())],
      ),
    );
    testWidgets(
      'ev order dark',
      (t) => _shot(
        t,
        'wiz_ev_dark',
        route: '/ev',
        dark: true,
        overrides: [evOrderRepositoryProvider.overrideWithValue(_FakeEv())],
      ),
    );
    testWidgets(
      'ev order large text',
      (t) => _shot(
        t,
        'wiz_ev_xl',
        route: '/ev',
        textScale: 1.35,
        overrides: [evOrderRepositoryProvider.overrideWithValue(_FakeEv())],
      ),
    );
  });

  group('support', () {
    testWidgets(
      'tickets',
      (t) => _shot(
        t,
        'support_tickets',
        route: '/account/support',
        overrides: _supportOverrides(),
      ),
    );
    testWidgets(
      'tickets dark',
      (t) => _shot(
        t,
        'support_tickets_dark',
        route: '/account/support',
        dark: true,
        overrides: _supportOverrides(),
      ),
    );
    testWidgets(
      'chat',
      (t) => _shot(
        t,
        'support_chat',
        route: '/account/support/t1',
        overrides: _supportOverrides(),
      ),
    );
    testWidgets(
      'chat keyboard',
      (t) => _shot(
        t,
        'support_chat_kb',
        route: '/account/support/t1',
        keyboard: true,
        overrides: _supportOverrides(),
      ),
    );
    testWidgets(
      'chat large text',
      (t) => _shot(
        t,
        'support_chat_xl',
        route: '/account/support/t1',
        textScale: 1.35,
        overrides: _supportOverrides(),
      ),
    );
    testWidgets(
      'chat SE',
      (t) => _shot(
        t,
        'support_chat_se',
        route: '/account/support/t1',
        se: true,
        overrides: _supportOverrides(),
      ),
    );
  });

  group('meter', () {
    testWidgets(
      'printer',
      (t) => _shot(t, 'meter_printer', route: '/meter/printer'),
    );
    testWidgets(
      'reader',
      (t) => _shot(t, 'meter_reader', route: '/meter/reader'),
    );
    testWidgets(
      'vehicle info',
      (t) => _shot(t, 'meter_vehicle', route: '/meter/vehicle'),
    );
    testWidgets(
      'meter SE',
      (t) => _shot(t, 'meter_se', route: '/meter', se: true),
    );
  });

  group('ipad', () {
    for (final (name, dev) in [
      ('ipad', _ipad),
      ('ipad_land', _ipadLand),
      ('slide', _slideOver),
      ('land', _iphone15Land),
    ]) {
      testWidgets(
        '$name home',
        (t) => _shot(t, '${name}_home', route: '/', device: dev),
      );
      testWidgets(
        '$name confirm',
        (t) => _shot(
          t,
          '${name}_confirm',
          route: '/',
          device: dev,
          rides: _BookingRides(),
          act: _toConfirm,
        ),
      );
      testWidgets(
        '$name wallet',
        (t) => _shot(t, '${name}_wallet', route: '/wallet', device: dev),
      );
      testWidgets(
        '$name account',
        (t) => _shot(t, '${name}_account', route: '/account', device: dev),
      );
      testWidgets(
        '$name drive online',
        (t) => _shot(
          t,
          '${name}_drive',
          route: '/drive',
          device: dev,
          partner: _approved,
          queue: [_request('q1', 'Pavilion KL', 'Mont Kiara', 18.5, km: 7.2)],
          act: (t) async {
            await t.tap(find.text('You are offline'), warnIfMissed: false);
            await _settle(t, 10);
          },
        ),
      );
      testWidgets(
        '$name ride',
        (t) => _shot(
          t,
          '${name}_ride',
          route: '/ride/r1',
          device: dev,
          overrides: _trackingOverrides(_tracked('accepted')),
        ),
      );
      testWidgets(
        '$name admin',
        (t) => _shot(
          t,
          '${name}_admin',
          route: '/admin/dashboard',
          device: dev,
          admin: true,
        ),
      );
      testWidgets(
        '$name settings',
        (t) => _shot(
          t,
          '${name}_settings',
          route: '/account/settings',
          device: dev,
        ),
      );
      testWidgets(
        '$name welcome',
        (t) => _shot(
          t,
          '${name}_welcome',
          route: '/login',
          device: dev,
          signedIn: false,
        ),
      );
      testWidgets(
        '$name trips',
        (t) => _shot(
          t,
          '${name}_trips',
          route: '/trips',
          device: dev,
          past: [_ride('r1', 'completed'), _ride('r2', 'cancelled', fare: 12)],
        ),
      );
    }
  });

  group('scrolled', () {
    for (final (name, route) in [
      ('account', '/account'),
      ('settings', '/account/settings'),
      ('guide', '/account/guide'),
      ('profile', '/account/profile'),
      ('wallet', '/wallet'),
      ('safety', '/account/safety'),
      ('onboarding_docs', '/drive/onboarding'),
      ('admin_settings', '/admin/settings'),
      ('admin_display', '/admin/m/display'),
      ('permit', '/drive/permit'),
      ('admin_messaging', '/admin/messaging'),
    ]) {
      testWidgets(
        '$name end',
        (t) => _shot(
          t,
          'end_$name',
          route: route,
          admin: name.startsWith('admin'),
          overrides: name == 'onboarding_docs'
              ? _wizardOverrides(partnerRow: _partnerRow(_filledIn))
              : const [],
          act: (t) async {
            for (var i = 0; i < 6; i++) {
              await t.drag(
                find.byType(Scrollable).last,
                const Offset(0, -900),
                warnIfMissed: false,
              );
              await t.pump(const Duration(milliseconds: 100));
            }
            await _settle(t, 5);
          },
        ),
      );
    }
  });

  Future<void> tapKey(WidgetTester t, String key, [int settle = 8]) async {
    await t.tap(find.byKey(ValueKey(key)), warnIfMissed: false);
    await _settle(t, settle);
  }

  group('flows', () {
    testWidgets(
      'confirm promo',
      (t) => _shot(
        t,
        'flow_promo',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'promo-banner');
        },
      ),
    );
    testWidgets(
      'confirm ride options',
      (t) => _shot(
        t,
        'flow_ride_options',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'ride-options');
        },
      ),
    );
    testWidgets(
      'confirm ride options SE',
      (t) => _shot(
        t,
        'flow_ride_options_se',
        route: '/',
        se: true,
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'ride-options');
        },
      ),
    );
    testWidgets(
      'confirm payment',
      (t) => _shot(
        t,
        'flow_payment',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'confirm-payment');
        },
      ),
    );
    testWidgets(
      'confirm now or later',
      (t) => _shot(
        t,
        'flow_now_later',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'book-now-later');
        },
      ),
    );
    testWidgets(
      'confirm fare edit',
      (t) => _shot(
        t,
        'flow_fare_edit',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'confirm-fare-edit');
        },
      ),
    );
    testWidgets(
      'confirm book for',
      (t) => _shot(
        t,
        'flow_book_for',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'book-for-who');
        },
      ),
    );
    testWidgets(
      'confirm entrance',
      (t) => _shot(
        t,
        'flow_entrance',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'confirm-entrance');
        },
      ),
    );
    testWidgets(
      'confirm route',
      (t) => _shot(
        t,
        'flow_route',
        route: '/',
        rides: _BookingRides(),
        act: (t) async {
          await _toConfirm(t);
          await tapKey(t, 'confirm-route');
        },
      ),
    );
    testWidgets(
      'menu partner mode',
      (t) => _shot(
        t,
        'flow_partner_mode',
        route: '/',
        act: (t) async {
          await tapKey(t, 'home-menu');
          await tapKey(t, 'menu-partner-mode');
        },
      ),
    );
    testWidgets(
      'menu coming soon',
      (t) => _shot(
        t,
        'flow_coming_soon',
        route: '/',
        act: (t) async {
          await tapKey(t, 'home-menu');
          await t.tap(find.text('Freight'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'welcome page 2',
      (t) => _shot(
        t,
        'flow_welcome_2',
        route: '/login',
        signedIn: false,
        act: (t) async {
          await t.drag(
            find.byType(PageView),
            const Offset(-400, 0),
            warnIfMissed: false,
          );
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'account sign out',
      (t) => _shot(
        t,
        'flow_sign_out',
        route: '/account',
        act: (t) async {
          for (var i = 0; i < 6; i++) {
            await t.drag(
              find.byType(Scrollable).last,
              const Offset(0, -900),
              warnIfMissed: false,
            );
            await t.pump(const Duration(milliseconds: 100));
          }
          await t.tap(find.text('Logout'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'account delete',
      (t) => _shot(
        t,
        'flow_delete',
        route: '/account/settings/delete',
        act: (t) async {},
      ),
    );
    testWidgets(
      'drive auto accept',
      (t) => _shot(
        t,
        'flow_auto_accept',
        route: '/drive',
        partner: _approved,
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
          await t.drag(
            find.byKey(const ValueKey('map-sheet-handle')),
            const Offset(0, -600),
            warnIfMissed: false,
          );
          await _settle(t);
          await tapKey(t, 'auto-accept');
        },
      ),
    );
    testWidgets(
      'drive destination',
      (t) => _shot(
        t,
        'flow_destination',
        route: '/drive',
        partner: _approved,
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
          await t.drag(
            find.byKey(const ValueKey('map-sheet-handle')),
            const Offset(0, -600),
            warnIfMissed: false,
          );
          await _settle(t);
          await tapKey(t, 'destination-add');
        },
      ),
    );
    testWidgets(
      'drive menu',
      (t) => _shot(
        t,
        'flow_drive_menu',
        route: '/drive',
        partner: _approved,
        act: (t) async {
          await tapKey(t, 'partner-menu-button');
        },
      ),
    );
    testWidgets(
      'ride cancel',
      (t) => _shot(
        t,
        'flow_ride_cancel',
        route: '/ride/r1',
        overrides: _trackingOverrides(_tracked('accepted')),
        act: (t) async {
          await t.drag(
            find.byKey(const ValueKey('map-sheet-handle')),
            const Offset(0, -500),
            warnIfMissed: false,
          );
          await _settle(t);
          await t.tap(find.textContaining('Cancel').last, warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'ride sos',
      (t) => _shot(
        t,
        'flow_ride_sos',
        route: '/ride/r1',
        overrides: _trackingOverrides(_tracked('accepted')),
        act: (t) async {
          await t.tap(find.text('SOS'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'searching cancel',
      (t) => _shot(
        t,
        'flow_search_cancel',
        route: '/ride/r1',
        overrides: _trackingOverrides(_tracked('open')),
        act: (t) async {
          await t.drag(
            find.byKey(const ValueKey('map-sheet-handle')),
            const Offset(0, -500),
            warnIfMissed: false,
          );
          await _settle(t);
          await t.tap(find.textContaining('Cancel').last, warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'wallet trade',
      (t) => _shot(t, 'flow_trade', route: '/wallet/trade'),
    );
    testWidgets(
      'emergency add',
      (t) => _shot(
        t,
        'flow_emergency_add',
        route: '/account/emergency',
        keyboard: true,
        act: (t) async {
          await t.tap(find.text('Add contact'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'my ride add driver',
      (t) => _shot(
        t,
        'flow_my_ride_add',
        route: '/account/my-ride',
        keyboard: true,
        act: (t) async {
          await t.tap(find.text('Add driver'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'my qr generate',
      (t) => _shot(
        t,
        'flow_my_qr_generate',
        route: '/account/my-qr',
        act: (t) async {
          await t.tap(find.text('Generate'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'help answer',
      (t) => _shot(
        t,
        'flow_help_answer',
        route: '/account/help',
        act: (t) async {
          await t.tap(find.text('How do I book a ride?'), warnIfMissed: false);
          await _settle(t, 15);
        },
      ),
    );
    testWidgets(
      'guide open',
      (t) => _shot(
        t,
        'flow_guide_open',
        route: '/account/guide',
        act: (t) async {
          await t.tap(find.text('Booking a ride'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
  });

  group('requested', () {
    for (final (tab, name) in [
      ('commission-tab-settings', 'settings'),
      ('commission-tab-tiers', 'tiers'),
      ('commission-tab-promotions', 'promotions'),
      ('commission-tab-reports', 'reports'),
    ]) {
      testWidgets(
        'commission $name',
        (t) => _shot(
          t,
          'req_commission_$name',
          route: '/admin/commission',
          admin: true,
          act: (t) => tapKey(t, tab),
        ),
      );
      testWidgets(
        'commission $name large text',
        (t) => _shot(
          t,
          'req_commission_${name}_xl',
          route: '/admin/commission',
          admin: true,
          textScale: 1.35,
          act: (t) => tapKey(t, tab),
        ),
      );
    }
    testWidgets(
      'commission add rate',
      (t) => _shot(
        t,
        'req_commission_add',
        route: '/admin/commission',
        admin: true,
        act: (t) => tapKey(t, 'commission-add'),
      ),
    );
    testWidgets(
      'commission add rate SE',
      (t) => _shot(
        t,
        'req_commission_add_se',
        route: '/admin/commission',
        admin: true,
        se: true,
        act: (t) => tapKey(t, 'commission-add'),
      ),
    );
    testWidgets(
      'commission add rate country picker',
      (t) => _shot(
        t,
        'req_commission_add_country',
        route: '/admin/commission',
        admin: true,
        keyboard: true,
        act: (t) async {
          await tapKey(t, 'commission-add');
          await t.tap(
            find.byType(SearchableDropdownFormField<String>).first,
            warnIfMissed: false,
          );
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'statements layout',
      (t) => _shot(
        t,
        'req_statements_layout',
        route: '/admin/m/partner-statements',
        admin: true,
        act: (t) => tapKey(t, 'statements-tab-layout'),
      ),
    );
    testWidgets(
      'statements layout SE',
      (t) => _shot(
        t,
        'req_statements_layout_se',
        route: '/admin/m/partner-statements',
        admin: true,
        se: true,
        act: (t) => tapKey(t, 'statements-tab-layout'),
      ),
    );
    testWidgets(
      'statements layout dark',
      (t) => _shot(
        t,
        'req_statements_layout_dark',
        route: '/admin/m/partner-statements',
        admin: true,
        dark: true,
        act: (t) => tapKey(t, 'statements-tab-layout'),
      ),
    );
    for (final (name, floor, dark, scale) in [
      ('ok', 10.0, false, 1.0),
      ('blocked', 50.0, false, 1.0),
      ('blocked_dark', 50.0, true, 1.0),
      ('blocked_xl', 50.0, false, 1.35),
    ]) {
      testWidgets(
        'drive credit $name',
        (t) => _shot(
          t,
          'req_drive_credit_$name',
          route: '/drive',
          partner: _approved,
          dark: dark,
          textScale: scale,
          overrides: [creditFloorProvider.overrideWith((ref) async => floor)],
          act: (t) async {
            await t.drag(
              find.byKey(const ValueKey('map-sheet-handle')),
              const Offset(0, -600),
              warnIfMissed: false,
            );
            await _settle(t);
          },
        ),
      );
    }
  });

  group('more', () {
    for (final r in [
      'share/abc123',
      'verify/abc123',
      'install/ios',
      'nowhere-at-all',
      'q/driver/XYZ',
    ]) {
      testWidgets(
        r,
        (t) => _shot(
          t,
          'more_${r.replaceAll(RegExp('[^a-z]'), '_')}',
          route: '/$r',
        ),
      );
    }
    for (final m in [
      'user-edit',
      'partner-edit',
      'vehicle-edit',
      'partner-add',
      'vehicle-add',
      'help-articles',
      'fare-ai',
      'ip-access',
      'api-keys',
      'messaging',
      'mock',
      'service-settings',
      'document-type',
      'multi-gate-places',
      'trace-fraud',
      'ble-report',
      'always-on',
      'backend',
      'user-id-documents',
      'get-coin',
      'ev-profiles',
      'ev-vehicle-inventory',
      'ev-finance-options',
      'ev-order-fee',
      'fare-ai-logs',
      'assign-service',
      'vehicle-make-model',
      'app-icon',
      'claude-access',
    ]) {
      testWidgets(
        'm $m',
        (t) => _shot(
          t,
          'more_m_${m.replaceAll('-', '_')}',
          route: '/admin/m/$m',
          admin: true,
        ),
      );
    }
    testWidgets(
      'm claude-access large text',
      (t) => _shot(
        t,
        'more_m_claude_access_xl',
        route: '/admin/m/claude-access',
        admin: true,
        textScale: 1.35,
      ),
    );
    testWidgets(
      'm claude-access SE',
      (t) => _shot(
        t,
        'more_m_claude_access_se',
        route: '/admin/m/claude-access',
        admin: true,
        se: true,
      ),
    );
    testWidgets(
      'm claude-access dark',
      (t) => _shot(
        t,
        'more_m_claude_access_dark',
        route: '/admin/m/claude-access',
        admin: true,
        dark: true,
      ),
    );
    testWidgets(
      'admin support chat',
      (t) => _shot(
        t,
        'more_admin_support_chat',
        route: '/admin/support/t1',
        admin: true,
        overrides: _supportOverrides(),
      ),
    );
    testWidgets(
      'admin push',
      (t) => _shot(t, 'more_admin_push', route: '/admin/push', admin: true),
    );
    testWidgets(
      'admin push keyboard',
      (t) => _shot(
        t,
        'more_admin_push_kb',
        route: '/admin/push',
        admin: true,
        keyboard: true,
        act: (t) async {
          await t.tap(find.byType(TextField).first, warnIfMissed: false);
          await _settle(t, 3);
        },
      ),
    );
    testWidgets(
      'drive scheduled',
      (t) => _shot(
        t,
        'more_drive_scheduled',
        route: '/drive/scheduled',
        partner: _approved,
      ),
    );
    testWidgets(
      'meter trip log',
      (t) => _shot(
        t,
        'more_meter_log',
        route: '/meter',
        act: (t) async {
          await t.tap(find.text('Trip log'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'meter settings',
      (t) => _shot(
        t,
        'more_meter_settings',
        route: '/meter',
        act: (t) async {
          await t.tap(find.text('Settings'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'ride with offers',
      (t) => _shot(
        t,
        'more_ride_offers',
        route: '/ride/r1',
        overrides: _trackingOverrides(
          _tracked(
            'open',
            extra: {
              'offers': [
                {
                  'partner_id': 'd1',
                  'partner_name': 'Ravi Kumar',
                  'amount': 26.0,
                  'rating': 4.8,
                  'vehicle': 'Perodua Bezza',
                  'plate': 'WXY 1234',
                  'eta_min': 4,
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                },
                {
                  'partner_id': 'd2',
                  'partner_name': 'Siti Nor',
                  'amount': 23.5,
                  'rating': 4.9,
                  'vehicle': 'Proton Saga',
                  'plate': 'VAB 8821',
                  'eta_min': 7,
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                },
              ],
            },
          ),
        ),
      ),
    );
  });

  group('scheduled', () {
    const on = ScheduledRidesConfig(enabled: true, feeFixed: 2);
    testWidgets(
      'confirm now or later',
      (t) => _shot(
        t,
        'sched_confirm',
        route: '/',
        rides: _BookingRides(),
        sched: on,
        act: _toConfirm,
      ),
    );
    final rows = [
      ScheduledRide.fromRow({
        'id': 's1',
        'pickup_at': DateTime.now()
            .add(const Duration(hours: 5))
            .toUtc()
            .toIso8601String(),
        'status': 'open',
        'rider_id': 'me',
        'service': 'Ride',
        'pickup_address': 'Eco Majestic, Semenyih',
        'drop_address': 'KLIA2, Sepang',
        'fare': 68.5,
        'scheduling_fee': 2,
        'currency': 'MYR',
        'distance_km': 52.1,
      }),
      ScheduledRide.fromRow({
        'id': 's2',
        'pickup_at': DateTime.now()
            .add(const Duration(days: 2))
            .toUtc()
            .toIso8601String(),
        'status': 'accepted',
        'rider_id': 'me',
        'service': 'XL',
        'pickup_address': 'KLCC, Kuala Lumpur',
        'drop_address': 'Genting Highlands',
        'fare': 120,
        'scheduling_fee': 2,
        'currency': 'MYR',
        'distance_km': 55,
        'partner_id': 'd1',
        'booked_for_name': 'Mak',
        'booked_for_phone': '+60111111111',
      }),
    ];
    testWidgets(
      'scheduled list',
      (t) => _shot(
        t,
        'sched_list',
        route: '/trips/scheduled',
        sched: on,
        overrides: [upcomingScheduledRidesProvider.overrideWithValue(rows)],
      ),
    );
    testWidgets(
      'scheduled list large text',
      (t) => _shot(
        t,
        'sched_list_xl',
        route: '/trips/scheduled',
        textScale: 1.35,
        sched: on,
        overrides: [upcomingScheduledRidesProvider.overrideWithValue(rows)],
      ),
    );
    testWidgets(
      'home with scheduled',
      (t) => _shot(
        t,
        'sched_home',
        route: '/',
        sched: on,
        overrides: [upcomingScheduledRidesProvider.overrideWithValue(rows)],
      ),
    );
    testWidgets(
      'account with scheduled',
      (t) => _shot(
        t,
        'sched_account',
        route: '/account',
        sched: on,
        overrides: [upcomingScheduledRidesProvider.overrideWithValue(rows)],
      ),
    );
  });

  group('edge', () {
    final longProfile = Profile({
      ..._profile.raw,
      'name': 'Tengku Nur Aisyah Humaira binti Tengku Abdul Rahman Al-Haj',
      'display_id': 'GR-1048291',
    });
    const from =
        'Jalan Persiaran Eco Majestic Utama 3/12, Taman Eco Majestic Fasa 2B, Semenyih, Selangor';
    const to =
        'Suria KLCC Shopping Centre, Entrance 3 beside the aquarium, Kuala Lumpur City Centre';
    final longRide = _tracked(
      'accepted',
      extra: {
        'pickup_name': from,
        'drop_name': to,
        'partner_name': 'Muhammad Ravindran Kumar a/l Subramaniam',
        'fare': 1234.5,
        'ride_fare': 1234.5,
      },
    );
    testWidgets(
      'long name account',
      (t) => _shot(t, 'edge_account', route: '/account', profile: longProfile),
    );
    testWidgets(
      'long name menu',
      (t) => _shot(
        t,
        'edge_menu',
        route: '/',
        profile: longProfile,
        act: (t) => tapKey(t, 'home-menu', 10),
      ),
    );
    testWidgets(
      'long name profile',
      (t) => _shot(
        t,
        'edge_profile',
        route: '/account/profile',
        profile: longProfile,
      ),
    );
    testWidgets(
      'long name receive',
      (t) => _shot(
        t,
        'edge_receive',
        route: '/wallet/receive',
        profile: longProfile,
      ),
    );
    testWidgets(
      'long addresses trips',
      (t) => _shot(
        t,
        'edge_trips',
        route: '/trips',
        past: [_ride('r1', 'completed', from: from, to: to, fare: 1234.5)],
      ),
    );
    testWidgets(
      'long addresses ride',
      (t) => _shot(
        t,
        'edge_ride',
        route: '/ride/r1',
        overrides: _trackingOverrides(longRide),
      ),
    );
    testWidgets(
      'long addresses ride up',
      (t) => _shot(
        t,
        'edge_ride_up',
        route: '/ride/r1',
        overrides: _trackingOverrides(longRide),
        act: (t) async {
          await t.drag(
            find.byKey(const ValueKey('map-sheet-handle')),
            const Offset(0, -500),
            warnIfMissed: false,
          );
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'long addresses driver queue',
      (t) => _shot(
        t,
        'edge_queue',
        route: '/drive',
        partner: _approved,
        queue: [_request('q1', from, to, 1234.5, km: 52.3)],
        act: (t) async {
          await t.tap(find.text('You are offline'), warnIfMissed: false);
          await _settle(t, 10);
        },
      ),
    );
    testWidgets(
      'long addresses driver trip',
      (t) => _shot(
        t,
        'edge_drive_trip',
        route: '/drive/trip/r1',
        partner: _approved,
        overrides: _trackingOverrides(
          RideRequest({
            ...longRide.raw,
            'rider_id': 'rider',
            'partner_id': 'me',
            'rider_name': 'Tengku Nur Aisyah Humaira binti Tengku Abdul Rahman',
          }),
        ),
      ),
    );
    testWidgets(
      'long addresses home ongoing',
      (t) => _shot(
        t,
        'edge_home_ongoing',
        route: '/',
        rides: _FakeRides(
          ongoing: RideRequest({...longRide.raw, 'status': 'open'}),
        ),
      ),
    );
    testWidgets(
      'set pin mismatch',
      (t) => _shot(
        t,
        'edge_pin_mismatch',
        screen: const SetPinScreen(),
        keyboard: true,
        act: (t) async {
          final fields = find.byType(TextField);
          await t.enterText(fields.at(0), '123456');
          await t.enterText(fields.at(1), '654321');
          await t.tap(find.text('Save PIN'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'phone invalid',
      (t) => _shot(
        t,
        'edge_phone_invalid',
        route: '/login/phone',
        signedIn: false,
        keyboard: true,
        act: (t) async {
          await t.enterText(find.byType(TextField).first, '12');
          await t.tap(find.text('Next'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'vehicle plate empty',
      (t) => _shot(
        t,
        'edge_plate_empty',
        route: '/drive/vehicles/new',
        partner: _approved,
        overrides: _wizardOverrides(
          partnerRow: _partnerRow({..._filledIn, 'status': 'approved'}),
        ),
        act: (t) async {
          await t.tap(find.text('Continue'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'add contact empty',
      (t) => _shot(
        t,
        'edge_contact_empty',
        route: '/account/emergency',
        keyboard: true,
        act: (t) async {
          await t.tap(find.text('Add contact'), warnIfMissed: false);
          await _settle(t);
          await t.tap(find.text('Save'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
    testWidgets(
      'change phone empty',
      (t) => _shot(
        t,
        'edge_change_phone_empty',
        route: '/account/settings/phone',
        act: (t) async {
          await t.tap(find.text('Send code'), warnIfMissed: false);
          await _settle(t);
        },
      ),
    );
  });

  group('session access', () {
    Widget host() => Scaffold(
      appBar: AppBar(title: const Text('SMS / WhatsApp')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [SessionAccessCard(devices: [])],
      ),
    );
    final keys = [
      sessionKeysProvider.overrideWith(
        (ref) async => [
          for (final r in [
            {
              'id': 'k1',
              'label': 'Tester iPhone 15',
              'created_at': '2026-10-18T06:00:00Z',
              'last_used_at': '2026-10-18T08:30:00Z',
              'expires_at': '2026-11-18T06:00:00Z',
              'internet_device_id': null,
            },
            {
              'id': 'k2',
              'label': 'CI runner',
              'created_at': '2026-10-10T06:00:00Z',
              'last_used_at': null,
              'expires_at': '2026-10-17T06:00:00Z',
              'revoked_at': '2026-10-15T00:00:00Z',
            },
          ])
            ?SessionKey.fromRow(r),
        ],
      ),
    ];
    testWidgets(
      'empty',
      (t) => _shot(
        t,
        'sa_empty',
        screen: host(),
        admin: true,
        overrides: [
          sessionKeysProvider.overrideWith((ref) async => const <SessionKey>[]),
        ],
      ),
    );
    testWidgets(
      'keys',
      (t) => _shot(t, 'sa_keys', screen: host(), admin: true, overrides: keys),
    );
    testWidgets(
      'keys large text',
      (t) => _shot(
        t,
        'sa_keys_xl',
        screen: host(),
        admin: true,
        textScale: 1.35,
        overrides: keys,
      ),
    );
    testWidgets(
      'keys SE',
      (t) => _shot(
        t,
        'sa_keys_se',
        screen: host(),
        admin: true,
        se: true,
        overrides: keys,
      ),
    );
    testWidgets(
      'keys dark',
      (t) => _shot(
        t,
        'sa_keys_dark',
        screen: host(),
        admin: true,
        dark: true,
        overrides: keys,
      ),
    );
  });

  group('partner', () {
    testWidgets(
      'drive (not a partner)',
      (t) => _shot(t, 'drive_none', route: '/drive'),
    );
    testWidgets(
      'drive dark',
      (t) => _shot(t, 'drive_none_dark', route: '/drive', dark: true),
    );
    testWidgets(
      'drive large text',
      (t) => _shot(t, 'drive_none_xl', route: '/drive', textScale: 1.35),
    );
    testWidgets(
      'onboarding',
      (t) => _shot(t, 'drive_onboarding', route: '/drive/onboarding'),
    );
    testWidgets(
      'vehicles',
      (t) => _shot(t, 'drive_vehicles', route: '/drive/vehicles'),
    );
    testWidgets(
      'vehicle new',
      (t) => _shot(t, 'drive_vehicle_new', route: '/drive/vehicles/new'),
    );
    testWidgets(
      'earnings',
      (t) => _shot(t, 'drive_earnings', route: '/drive/earnings'),
    );
    testWidgets(
      'statements',
      (t) => _shot(t, 'drive_statements', route: '/drive/statements'),
    );
    testWidgets(
      'history',
      (t) => _shot(t, 'drive_history', route: '/drive/history'),
    );
    testWidgets(
      'permit',
      (t) => _shot(t, 'drive_permit', route: '/drive/permit'),
    );
    testWidgets(
      'my ride code',
      (t) => _shot(t, 'drive_my_ride', route: '/drive/my-ride'),
    );
    testWidgets('meter', (t) => _shot(t, 'meter', route: '/meter'));
  });
}
