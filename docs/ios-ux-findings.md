# iOS UI/UX findings (tester session)

Rendered from `claude/magical-fermat-6o8l12` (head 8847ce8) with
`test/ios_shots_test.dart`: iPhone 15 frame (393×852, TargetPlatform.iOS,
59 pt / 34 pt safe areas), iPhone SE, iPhone landscape, iPad, iPad Slide
Over; light and dark; text scale 1.0 and 1.3; keyboard up where it matters.
All items were sent to the fixing session as they were found. Status column
is updated on every push to the branch. Verified against 1bc4952 ("UX fixes
from the web, iOS and Android test rounds"): 24 fixed, 2 partly, see the table.

| # | Screen | Finding | Where | Status |
| --- | --- | --- | --- | --- |
| 1 | Wallet | Balance cards fixed at 230 pt in a `Wrap`: one per row, right half of the phone empty; balance wraps at large text | `wallet_screen.dart:67-73` | fixed in 1bc4952 |
| 2 | Wallet → history | Title truncates to "Transaction histo…" next to the month picker (iOS centres titles) | `wallet_history_screen.dart:46` | open |
| 3 | Settings → Appearance | "System" segment breaks into "Syste / m" at text scale 1.3 | `settings_screen.dart:40-44` | fixed in 1bc4952 |
| 4 | Home | Pickup pill ellipsizes "Set pickup locati…" at scale 1.3 and at 320 pt | `home_parts.dart:494` | fixed in 1bc4952 |
| 5 | Home | Collapsed sheet's search bar sits in the home-indicator zone (`navLift` is Android-only) | `home_screen.dart:1814-1816` | fixed in 1bc4952 |
| 6 | Trips list | Route drawn as one line "pickup → drop", so the drop-off is always cut; date/status wraps with a dangling "·" | `trip_history_view.dart:142-143` | fixed in 1bc4952 |
| 7 | Account header | "+60… ·" / "GR-10482" wraps with a dangling separator at large text | `account_screen.dart:136` | fixed in 1bc4952 |
| 8 | Wallet quick actions | "GET.coin QR" tile grows taller than its siblings at large text | `wallet_screen.dart` ~113 | fixed in 1bc4952 |
| 9 | Ride tracking, driver trip | SOS pill covers the OpenStreetMap credit and its ⓘ | `ride_tracking_screen.dart:1040-1045`, `map_credit.dart:67` | fixed in 1bc4952 |
| 10 | Driver online | Floating request cards run under the map-type / recenter buttons (SE with 2 requests, iPhone 15 with 3+) | `partner_screen.dart` queue column | fixed in 1bc4952 |
| 11 | Ride sheet | Resting height adds no bottom inset: "Done" (completed) and "Closing in 4s" (cancelled) under the home indicator | `map_sheet_layout.dart:617` | open |
| 12 | Confirm step | "Their name and phone go to the d…" ellipsized at large text | `confirm_parts.dart` book-for row | fixed in 1bc4952 |
| 13 | Driver trip sheet | "1 passenger ·" / "Cash" wraps at large text | `partner_trip_screen.dart` | open |
| 14 | Trip complete card | Cash booking shows a red "GET.wallet RM0.00 … Not enough" line | `ride_payment_overlay.dart` | UX note |
| 15 | Admin → Dashboard | Tiles overflow (RenderFlex 11 px, 31 px at large text, 34 px at 320 pt, 54 px iPad landscape) | `dashboard_screen.dart:52-78` | fixed in 1bc4952 |
| 16 | Admin → Session History | Title truncates to "Session &…" behind four action icons | `session_history_screen.dart` | fixed in 1bc4952 |
| 17 | Searchable dropdown (#401) | Dialog squeezed by the keyboard: 4 rows on iPhone 15, 2 on SE at large text; suggestion: full-height sheet on phones | `search_select.dart` `_SearchDialog` | suggestion |
| 18 | iPhone landscape | Rail layout chosen at 852×393 and overflows by 14 px on every tab | `app_shell.dart:49,64` | fixed in 1bc4952 |
| 19 | iPhone landscape | Welcome title clipped behind the page dots; home/ride sheets leave ~190 pt of map | `welcome_screen.dart`, `home_screen.dart:1373` | fixed in 1bc4952 |
| 20 | iPad landscape admin | Rail with 13 labelled destinations overflows by 143 px; last four unreachable | `admin_shell.dart:132` | fixed in 1bc4952 |
| 21 | iPad Slide Over | Dashboard tiles overflow by 34 px (same as #15) | `dashboard_screen.dart` | fixed in 1bc4952 |
| 22 | iPad portrait wallet | Three 230 pt cards wrap 2 + 1 with 40 % of the width empty (same as #1) | `wallet_screen.dart:67-73` | fixed in 1bc4952 |
| 23 | Promo sheet | "Apply" sits in the home-indicator zone (pads `viewInsets` only) | `confirm_parts.dart:1592` | fixed in 1bc4952 |
| 24 | Side menu header | Long names truncate "Nur Aisyah binti Rah…" (`maxLines: 1`) | `side_menu_style.dart:150` | fixed in 1bc4952 |
| 25 | Accent buttons | White on `brandAccent` 0xFF2DABE2 is 2.6:1 (AA needs 4.5 / 3.0): Find a driver, Accept for RM…, Confirm time, Keep sharing, Done, Exit admin, Partner/Passenger Mode | `app.dart:122` | fixed in 1bc4952 |
| 26 | Booking flow | Tap targets under 44 pt and unlabelled: vehicle ⓘ 22 pt no label, route card rows 23 pt, Entrance 24 pt, Add stop 32 pt, search Close 36 pt, payment × 40 pt unlabelled, keypad backspace unlabelled | `home_parts.dart:240`, `confirm_parts.dart:94-132,355` | partly fixed in 1bc4952 (route card rows 23 pt, Entrance 24 pt, Add stop 32 pt, welcome dots 32 pt remain) |
| 27 | Icon buttons | No `tooltip:` (VoiceOver "button"): admin menu, refresh on Dashboard/Rides/Support/EV Orders, Set-PIN ×, ride-chat back, Messaging icons, one Current-trip app-bar icon | `admin_widgets.dart:37`, `dashboard_screen.dart:46`, … | partly fixed in 1bc4952 (one Current-trip app-bar icon still unlabelled) |
| 28 | Muted text | Below AA on light surfaces: "Your ride, your way." 2.4, "Appearance" 2.4, "City" 2.5, admin captions 2.4, pickup-time wheel 2.5, "call 999." 1.9, request card "Cash · 1 pax" 1.9 | muted / onSurfaceVariant greys | open |
| 30 | Add contact dialog | Plain Column in an AlertDialog: overflows 53 px on an iPhone SE with the keyboard up (Cancel lands on the Phone field), 1.2 px at text scale 1.3 | `emergency_contacts_screen.dart:65-67` | fixed in 1bc4952 |
| 31 | Multi-field forms | No `textInputAction` next/done (Set PIN, Edit profile, Add vehicle, Add contact, Change phone, Add reader/printer, Add rate) | various | minor |
| 32 | Map screens | No `SystemUiOverlayStyle` on app-bar-less screens (home, Drive, Welcome): status-bar text style follows the last AppBar | `home_screen.dart`, `partner_screen.dart`, `welcome_screen.dart` | verify on device |
| 33 | Admin → Push | Segmented labels break words at default size: "Everyon / e", "Everywh / ere" | `push_screen.dart` | fixed in 1bc4952 |
| 34 | Add contact dialog | Save with an empty name or phone closes the dialog silently, nothing saved | `emergency_contacts_screen.dart:75-81` | open |
| 35 | Set PIN, Add vehicle | Validation shown as a SnackBar over the button instead of inline under the field | `set_pin_screen.dart:56`, `vehicle_screens.dart` | minor |
| 36 | Trips list | Long addresses ellipsize at one line per row, cutting the area / city | `trip_history_view.dart` | open |
| 37 | Driver request cards | Same one-line ellipsis on pickup and drop with long addresses | `partner_screen.dart` | open |
| 38 | Session access card | Subtitle joins empty parts: "· · Ends 18 Nov…" when a key has no test number / scopes | `session_access_card.dart:101` | minor |
| 29 | Contacts picker | "Choose from contacts" exists only on the web; iOS has a permission-free CNContactPickerViewController | `emergency_contacts_screen.dart:32-38` | suggestion |

Sweeps over every screen: dark mode, text scale 1.3, iPhone SE and iOS
Bold Text found nothing beyond #15 and #30 (bold text: no overflows at all).

Checked and fine on iPhone: sign-in flow (welcome, phone, OTP with
`oneTimeCode` autofill, PIN, set PIN, closed registrations), keyboard
handling on every text screen, the booking confirm step and its sheets
(fare info, add stop, payment, entrance, book for, pickup time, cancel
reasons, location sharing), ride tracking in every status, driver
offline/online/request/trip screens, support tickets and chat, help
assistant, user guide, wallet receive / my QR / my ride, partner onboarding
and vehicle wizards, TEKSI EV step 1, meter console (landscape), printer /
reader / vehicle-info screens, admin list pages and settings, scrolled-to-end
states of every long page, Info.plist usage strings for location, camera,
photos, microphone, Bluetooth and local network.

## Re-rendering

```
SHOTS_DIR=/tmp/shots flutter test test/ios_shots_test.dart --update-goldens
```

Groups: `auth`, `rider`, `booking`, `tracking`, `driver`, `keyboard`,
`sheets`, `admin`, `picker`, `wizards`, `support`, `meter`, `ipad`,
`scrolled`, `flows`, `partner`; pick one with `--name "^rider "`.
`SHOTS_DIR/log.txt` lists overflows and exceptions per screenshot. With
`AUDIT=1` it also runs the iOS tap-target, VoiceOver-label and WCAG contrast
guidelines on every screenshot and writes `SHOTS_DIR/audit.txt`.
