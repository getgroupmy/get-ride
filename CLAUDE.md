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
