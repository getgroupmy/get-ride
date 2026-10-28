/// Every booking module of the app, and where Family reaches it (CLAUDE.md,
/// "Every booking module works with Family"; migration 0317). The server's
/// registry is `booking_modules`: each key here is registered there by a
/// migration (`family_register_module`), and Admin › People › Family lists
/// every registered module in its matrix, switched off until the admin turns
/// it on. test/family_modules_test.dart fails when a booking table or a key
/// here is not wired to Family. Pure.
library;

class BookingModule {
  const BookingModule(
    this.key,
    this.name, {
    this.tables = const [],
    this.repositories = const [],
    this.screens = const [],
    this.built = true,
  });

  /// As registered in `booking_modules`.
  final String key;
  final String name;

  /// The tables its bookings are kept in (a table with a rider, a status and
  /// a fare is a booking table). Each has a Family trigger in a migration.
  final List<String> tables;

  /// The app files that book it. Each passes Family: payment `Family` (the
  /// member's own trip) or the `family` passenger (the host books for a
  /// member or a child), see [familyBookingColumns] in core/family.dart.
  final List<String> repositories;

  /// The booking screens: each shows the `Family · <host>'s GET.wallet` row
  /// (familyPayOptionProvider) where the admin allows it.
  final List<String> screens;

  /// False for a key registered ahead of a module being built elsewhere.
  final bool built;
}

const familyModuleRide = 'ride';
const familyModuleScheduled = 'scheduled_ride';
const familyModuleCityToCity = 'city_to_city';
const familyModuleFreight = 'freight';
const familyModuleCourier = 'courier';
const familyModuleTips = 'tips';
const familyModuleSeatTrip = 'seat_trip';

const bookingModules = <BookingModule>[
  BookingModule(familyModuleRide, 'Ride',
      tables: ['ride_requests'],
      repositories: ['lib/src/data/ride_repository.dart'],
      screens: ['lib/src/features/ride/home_screen.dart']),
  // Booked on the same screen as a ride now, with a time.
  BookingModule(familyModuleScheduled, 'Scheduled ride',
      tables: ['scheduled_rides'],
      repositories: ['lib/src/data/ride_repository.dart', 'lib/src/data/scheduled_ride_repository.dart'],
      screens: ['lib/src/features/ride/home_screen.dart']),
  BookingModule(familyModuleCityToCity, 'City to City',
      tables: ['c2c_bookings'],
      repositories: ['lib/src/data/city_to_city_repository.dart'],
      screens: ['lib/src/features/ride/city_to_city_steps.dart']),
  BookingModule(familyModuleFreight, 'Freight',
      tables: ['ride_requests'],
      repositories: ['lib/src/data/ride_repository.dart'],
      screens: ['lib/src/features/ride/freight_screen.dart']),
  BookingModule(familyModuleCourier, 'Courier',
      tables: ['ride_requests'],
      repositories: ['lib/src/data/ride_repository.dart'],
      screens: ['lib/src/features/ride/courier_screen.dart']),
  // A seat on a trip a driver posted (0310): a c2c_bookings row with a trip,
  // booked with c2c_book_seat (payment 'family', the family passenger).
  BookingModule(familyModuleSeatTrip, 'Seat trip',
      tables: ['c2c_bookings'],
      repositories: ['lib/src/data/city_to_city_repository.dart'],
      screens: ['lib/src/features/ride/city_to_city_seats.dart']),
  // Charges on a trip, not bookings, so no tables of their own: the payment
  // layer sends each to whoever paid the trip (0317, section 9). A GET.wallet
  // tip on a family-paid trip is the host's where the admin allows it; the
  // tip card says so.
  BookingModule(familyModuleTips, 'Tips',
      repositories: ['lib/src/data/city_ride_extras_repository.dart'],
      screens: ['lib/src/features/ride/city_extras_parts.dart']),
  // Floors, cold truck, parcel cover, a return leg: lines on the fare, paid
  // with the trip (ride_pay, method 'family'), booked on these screens.
  BookingModule('freight_addons', 'Freight add-ons',
      repositories: ['lib/src/data/ride_repository.dart'],
      screens: ['lib/src/features/ride/freight_screen.dart']),
  BookingModule('courier_addons', 'Courier add-ons',
      repositories: ['lib/src/data/ride_repository.dart'],
      screens: ['lib/src/features/ride/courier_screen.dart']),
  // Not Family: a membership, not a trip; and a business trip is paid by the
  // company, never by a family (FAMILY_BUSINESS, 0317).
  BookingModule('get_plus', 'GET.Plus', built: false),
  BookingModule('business_account', 'Business account', built: false),
];

/// The module a ride request books, as the server reads it
/// (family_ride_module, 0317): Courier, Freight, a scheduled ride, else Ride.
String rideBookingModule({bool scheduled = false, bool freight = false, bool courier = false}) {
  if (courier) return familyModuleCourier;
  if (freight) return familyModuleFreight;
  if (scheduled) return familyModuleScheduled;
  return familyModuleRide;
}

BookingModule? bookingModule(String key) {
  for (final m in bookingModules) {
    if (m.key == key) return m;
  }
  return null;
}
