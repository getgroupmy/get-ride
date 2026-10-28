# get-ride

## Every page, sheet and modal is listed in App Page Settings

Admin → Settings → App Page Settings shows every page, bottom sheet and modal
of the app and lets the admin change their look live (`lib/src/core/page_styles.dart`).
When you add one:

- Open sheets with `showAppSheet(id: '<area>.<name>', ...)`, modals with
  `showAppDialog(id: ...)` / `showAppGeneralDialog(id: ...)`, and pushed pages with
  `AppPageRoute(id: ...)` (`lib/src/widgets/page_style_host.dart`) — never the raw
  `showModalBottomSheet` / `showDialog` / `showGeneralDialog` / `MaterialPageRoute`.
  Router pages (`GoRoute`) are found on their own.
- Then run `dart run scripts/page_inventory.dart` to regenerate
  `lib/src/core/page_inventory.g.dart`.
- Items inside a surface that the admin should size or colour get tokens in
  `elementTokens` (`page_styles.dart`), read with `SurfaceStyle.of(context, '<surface id>')`.

`test/page_styles_test.dart` fails when the list is stale, a raw helper is used, or
an id is reused.

## Long lists can be searched

Any list the user picks from that can get long gets a search box
(`lib/src/widgets/search_select.dart`):

- Dropdowns use `SearchableDropdownFormField` (same arguments as
  `DropdownButtonFormField`; from 8 choices it opens a searchable list).
- One-tap pick dialogs use `showSearchPicker(...)`.
- Long chip, tick-box or record lists sit inside `ListSearchFilter`.

`test/search_select_test.dart` fails when a plain `DropdownButtonFormField` is used.

## Dates are typed in separate boxes

Every date the user enters — rider, driver or admin — is a `DateBoxesField`
(`lib/src/widgets/date_boxes.dart`): a day, a month and a year box with the
calendar as a shortcut button.

- The boxes follow the user's country (`lib/src/core/date_order.dart`):
  `dateOrderFor` gives day first for most countries, month first for the US
  and the Philippines, year first for China, Japan, Korea and a few others.
  The country is the profile's (`profiles.nationality`), else the phone's,
  else Malaysia.
- Give it a `controller` to keep the date as `yyyy-mm-dd`, as stored, and
  `firstDate` / `lastDate` for limits (an expiry from today, a birth date in
  the past).
- Show a date the user typed with `formatDateForUser` / `formatStoredDateForUser`
  so it reads in the same order.
- Open the calendar with `pickDateFromCalendar`, never a bare `showDatePicker`.

`test/date_boxes_test.dart` fails when a single-box date field (a `YYYY-MM-DD`
hint, `TextInputType.datetime`) or a bare `showDatePicker` appears outside the
widget, unless that file is on its allow-list with the reason (report date-range
filters, date-and-time pickers).

## Offer cards move the same way everywhere (locked by the owner)

Every incoming-offer card in every module (ride, scheduled, My Ride, Freight,
Courier, partner counter-offers and any new one) uses the shared motion in
`lib/src/widgets/offer_motion.dart`:

- A new offer slides in from the right, moving right to left into place with a small overshoot.
- An offer that is declined, expires, is withdrawn or is taken slides out to the left with a slight tilt (about −6°) and fades.
- Reduced motion turns off the slide and tilt.

Do not change the direction, tilt or timing unless the owner asks for it.
`test/offer_motion_test.dart` fails when the constants change or an offer card
animates on its own.

## Every booking module works with Family

Family (migration 0317) must work with every booking module, today's and any
added later. It is one shared layer, not code per module:

- Register the module's key in its migration:
  `select public.family_register_module('<key>', '<Name>');` (harmless to
  repeat), and add it to `bookingModules` in `lib/src/core/booking_modules.dart`
  with its booking tables, repositories and booking screens. Admin › People ›
  Family's Modules and Family matrix lists every registered module, switched
  off until the admin turns its boxes on.
- On the server, call the shared family functions, never your own copy:
  `family_attach_trip(module, trip id, booker, family passenger, amount, place,
  options, family pays)` from the booking's insert trigger (it runs
  `family_payer_for` and raises its FAMILY_* code), `family_trip_guard` and
  `family_trip_events` triggers for a trip with a driver (a child's pickup
  code, women drivers, the host told), and `family_can_view_location` for
  anything that shows where a member is.
- Money: charge the rider's GET.wallet with `ride_id` set to the trip's id
  (`wallet_transactions`), checking the balance of
  `family_wallet_owner(trip, rider, amount)`. The payment layer then sends the
  charge to whoever paid the trip, within the member's limits, for every
  charge type (fare, tips, waiting, luggage, add-ons, cancel and owed fees).
- In the app, show the `familyPayOptionProvider(<key>)` row
  ("Family · <host>'s GET.wallet", `withFamilyPayment`) on the booking screen and
  pass `familyBookingColumns(...)` (who it is for) with the booking; put
  `FamilyTripStrip` on the trip screen and `DriverChildCheck` on the driver's.
- Privacy is the owner's and not negotiable: only the Family viewer the member
  can see ("Shared with family", who can see), the logged God View look with a
  reason, and the admin's location rule. Nothing hidden or covert.

`test/family_modules_test.dart` fails when a booking table (a table with a
`rider_id`, a `status` and a fare or price) has no module or no Family trigger,
a file that books is not a module's repository, a key is not registered, or a
booking screen has no Family row.

## Parked work is listed in docs/KIV.md

`docs/KIV.md` is the owner's keep-in-view list: features they have parked.
Don't build an item from it until the owner asks. When a PR ships an item,
remove that item from `docs/KIV.md` in the same PR. Add a new item only when
the owner parks one.

## Popups are modals

Every message to the user is a modal with an OK, never a bar at the bottom: use `showInfo` / `showError` or `showAppNotice(id: 'notice.<area>', ...)` (`lib/src/widgets/app_notice.dart`), never `SnackBar` / `showSnackBar` — `test/app_notice_test.dart` fails otherwise.
