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

## Parked work is listed in docs/KIV.md

`docs/KIV.md` is the owner's keep-in-view list: features they have parked.
Don't build an item from it until the owner asks. When a PR ships an item,
remove that item from `docs/KIV.md` in the same PR. Add a new item only when
the owner parks one.

## Popups are modals

Every message to the user is a modal with an OK, never a bar at the bottom: use `showInfo` / `showError` or `showAppNotice(id: 'notice.<area>', ...)` (`lib/src/widgets/app_notice.dart`), never `SnackBar` / `showSnackBar` — `test/app_notice_test.dart` fails otherwise.
