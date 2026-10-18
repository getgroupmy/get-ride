# GET.ride vs inDrive vs Grab — iOS UX benchmark (tester session)

Compared on head 222a84e of `claude/magical-fermat-6o8l12`, using the iPhone
renders from `test/ios_shots_test.dart` for GET.ride and published material
for the two reference apps (Grab's own product pages and press releases,
inDrive's help centre and App Store listing, third-party walkthroughs; the
container cannot open the apps themselves, so competitor details are as
documented publicly, not freshly observed). Each row ends with what GET.ride
should take from it, if anything. "=" means GET.ride is on par.

## 1. Sign-in and first run

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Entry | Welcome carousel (2 slides) → phone → SMS code → 6-digit PIN; passkeys | Phone → SMS code; social sign-in in some markets | Phone → SMS code; Google / Apple / Facebook sign-in |
| Returning user | PIN (no SMS) or passkey | Stays signed in | Stays signed in |
| Permissions | Asked in context (location when booking) | Location on first open | Location on first open |

GET.ride is stronger here (no repeat SMS, passkeys). Two gaps:

- **Sign in with Apple** is absent. Both references offer a one-tap identity
  option; Apple also requires it when any other third-party login is offered
  (not the case today, so it is optional). Worth adding as a second button
  on Welcome (`welcome_screen.dart`) once the backend can link an Apple ID.
- **Welcome slide 1 copy** "Your ride, your way." is 2.4:1 against white
  (finding #28).

## 2. Home screen

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Layout | Map, pickup pill at top, bottom sheet with vehicle chips + "Where to & for how much?" | Map, big "Where to?" field, recent/saved places, service tabs (City / Intercity / Courier) | Services grid (Transport, Food, Mart…) then a "Where to?" card with saved places and recent |
| Saved places | Home / Work ("Add Home" with map pick) | Home / Work + favourites | Home / Work + favourites, synced |
| Scheduled ride | "Later" from the confirm step; upcoming card on home | Scheduled via pickup time | "Advance booking" with time picker, visible on home |
| Upcoming ride | Card under the search bar | Banner | Card on home |
| iOS extras | — | — | Home-screen widget, 3D-Touch / long-press quick actions ("Book a ride"), Siri shortcuts |

Recommendations:

- **Quick actions and a widget.** Add `UIApplicationShortcutItems` (Book a
  ride, Drive, Wallet / Scan & Pay) through `quick_actions`; a small
  `home_widget` for the upcoming ride is a later step. Cheap, visible, and
  Grab users expect it.
- **"Where to?" first.** Both references put the destination field above
  the vehicle choice; GET.ride shows the vehicle chips first, then the
  search bar (`home_parts.dart`). Swapping the order on the resting sheet
  puts the primary action where thumbs land and leaves the vehicle choice
  for the confirm step (where it is repeated anyway).
- **Landscape and side insets** (findings #41–#45, #48) do not apply to the
  references: both lock the rider app to portrait on iPhone. Locking
  portrait on iPhone (`UISupportedInterfaceOrientations` in Info.plist,
  keep iPad free) would close #41–#45, #48 and #52 in one change, if
  landscape on the phone is not a product requirement (the meter already
  forces landscape itself).

## 3. Entering pickup and destination

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Search | "Enter your route" dialog: From / To, Suggested / Saved chips, Recent | Full-screen search, recent + map pin | Full-screen search, recent, saved, "Choose on map" |
| Pickup accuracy | Drop pin, "Entrance" chip, multi-gate places from admin | Pin + address | Venues: curated pickup points with photo / text / video directions, chosen before booking; rendezvous distance down 40 % |
| Stops | Up to N stops, route sheet | Stops supported | Up to 2 stops |

Recommendations:

- **Show the entrance / gate choice before the fare**, the way Grab moved
  its venue directions earlier after finding riders ignored them post-booking.
  Today "Entrance" is a chip on the route card of the confirm step
  (`confirm_parts.dart:181`); surfacing the gate list as the last step of
  the search dialog when a multi-gate place is picked would mirror Grab.
- **Photo or text direction on the entrance sheet.** The admin already keeps
  multi-gate places; a one-line "Meet at Door 3, next to the taxi stand"
  note per gate (admin field + display in the entrance sheet) is the
  low-cost version of Grab's directions.
- **Map pin feedback.** Grab and Gojek attach a photo or label to the pin so
  the rider can confirm the spot. GET.ride's pill says "Pinned location";
  reverse-geocoding the pin to a short label (already done for the route
  sheet after batch 2 round 4) should also replace "Pinned location" on the
  confirm card.

## 4. Fare and vehicle choice (the inDrive comparison)

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Price model | Recommended fare, rider adjusts (bidding) or fixed per region; "Offer your fare" page with 64-pt amount | Recommended minimum, rider offers ≥ minimum, ± steppers, "Auto accept" toggle, demand hint | Fixed upfront fare per tier, surge shown as a multiplier / note |
| Vehicle list | Cards: name, seats, description, price, ETA, ⓘ fare details | List: class, price, ETA, seats | List: tier, price, ETA, icon; "Saver" / "Plus" tiers |
| Extras | Payment, promo, book-for-someone, options (comments), pickup time, entrance, add stop | Payment, comments, auto accept, "Need a child seat" style options | Payment, promo, notes to driver, Quiet ride, child seat, pet-friendly tiers |
| Price breakdown | ⓘ sheet with tolls, tax, demand trend | Help page | Fare details sheet |

GET.ride already matches inDrive's mechanics closely (its own code names
inDrive's screens). Gaps:

- **Tap targets on the cards** (finding #26): the ⓘ is 24 pt and
  unlabelled, where inDrive's and Grab's whole card row is the target.
- **"Later" on narrow rows** now shrinks to its icon (batch 2); Grab keeps a
  text label ("Now ▾") on the same row, which reads better than a lone
  clock icon. Consider "Now" / "Later" text with the icon when width allows
  and the icon alone only below 360 pt.
- **Demand / surge explanation.** inDrive shows "high demand" nudges on the
  fare; GET.ride has the trend arrows on the card. Fine, but the arrow
  needs a label for VoiceOver (part of #27).
- **Auto accept** exists in both; GET.ride's lives in the fare page
  (`offer_fare_screen.dart`). inDrive puts it on the main confirm sheet as
  a labelled switch; worth exposing on the confirm step when bidding is on.

## 5. Finding a driver / offers

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Waiting state | "Searching for drivers 0:00", "All drivers verified", radar pulse, fare line, Cancel | Offers list fills in real time; each card: price, ETA, name, rating, car + plate, countdown bar, Accept / Decline | "Finding you a driver…" progress bar with estimated wait, then driver card |
| Offer cards | Price, ETA, name, rating, rides, vehicle · plate, swipe to dismiss | Same + the driver's photo and a shrinking timer bar | n/a (no bidding) |
| No driver | Cancel reasons sheet | "Raise your fare" prompt with +RM step | Retry with a different tier suggestion |

Recommendations:

- **"Raise your fare" fallback.** When no offers arrive in ~30–60 s, inDrive
  prompts to raise by one step; Grab suggests another tier. GET.ride only
  counts up. A one-tap "+RM2 and search again" on the searching sheet
  (`searching_parts.dart`) is the single biggest conversion feature in
  inDrive's flow and is missing.
- **Expected wait.** Grab shows "usually 3–5 min"; the searching header
  could show the ETA band from `nearbyDrivers` instead of only the stopwatch.
- **Offer timer bar.** inDrive's cards shrink a bar as the offer expires;
  GET.ride's cards show no expiry. If offers do expire, show it.

## 6. Driver assigned and tracking

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Driver card | Name, photo, rating, car · plate, Call / Message, Cancel ride footer | Name, photo, rating, car colour + model + plate (plate large), Call / Chat | Plate in a large bordered box, car model + colour, driver photo, rating; "Driver is 3 min away"; quick-reply chips |
| Status | Title ("Driver on the way", "On trip") in the sheet | Status + ETA at top | Status + ETA + pickup instructions |
| Map | Driver marker, route, recenter, map type | Driver marker, route | Driver marker, ETA bubble, your pin with share-location toggle |
| iOS | — | — | Live Activity on the Lock Screen and Dynamic Island with ETA and plate |

Recommendations:

- **Plate as the hero.** Both references make the plate the largest text on
  the card, because it is what the rider matches against the kerb. GET.ride
  renders "car · plate" in titleMedium (`ride_tracking_screen.dart:702`).
  Put the plate in its own bordered box (titleLarge, monospace digits) with
  the model + colour under it.
- **ETA in the title.** "Driver on the way · 4 min" instead of only the
  status; the number already exists for the offer card (`etaMin`).
- **Live Activity (ActivityKit)** for the "driver on the way" and "on trip"
  states: ETA, plate and status on the Lock Screen and in the Dynamic
  Island. This is Grab's most visible iOS-only feature and the one riders
  notice when they lock the phone while waiting. Needs a small Swift
  extension plus the `live_activities` package; worth a ticket of its own.
- **Quick replies** ("I'm at the pickup point", "Running 2 minutes late")
  exist in the chat; Grab also surfaces them on the tracking card itself
  for the accepted state.

## 7. Safety

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Entry point | SOS pill on the map (999 + emergency contacts), Safety page in Account | SOS button, share trip, emergency contacts | Shield "Safety Centre" on every trip: Share my ride, Emergency SOS, report issue, AudioProtect toggle |
| Sharing | Share ride link (app bar), location sharing with the driver | Share trip | Share my ride with trusted contacts, automatic per ride if set |
| Audio | VoiceProtection (driver-side recording, opt-in) | — | AudioProtect (both parties opt in, 5-day retention) |
| Monitoring | — | — | Trip Monitoring: unexpected stops / route deviations trigger an in-app check |
| Verification | Driver documents + admin approval | Driver verification | Driver selfie checks, random during the day |

Recommendations:

- **One Safety entry point on the trip screen.** Grab's shield groups share,
  SOS, report and audio in one sheet; GET.ride splits them between the SOS
  pill (map), the share icon (app bar) and the location-sharing button.
  A "Safety" pill that opens a sheet with those four actions, keeping SOS
  as the first large button, matches rider expectations and also fixes the
  SOS pill's landscape / island placement (#48) by making it a sheet.
- **Trusted contacts auto-share.** Emergency contacts exist; add
  "Share every ride with…" so the link goes out on accept, as Grab does.
- **Rider-side VoiceProtection parity**: today only the driver records.
  Grab requires both parties to opt in; at least show the rider when a ride
  is being recorded (a small mic badge on the trip card) for consent.
- **Deviation check** is a backend feature; noting it as the one safety
  item neither GET.ride nor inDrive has.

## 8. Payment and trip end

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Methods | Cash, GET.wallet, GET.coin, QR; gateway via admin | Cash, card, wallet (market-dependent) | Cash, GrabPay wallet, cards, PayLater, Apple Pay in some markets |
| End of trip | "Trip complete" card: fare, total, Paid in cash / Pay now, Done; rating card | Rating with tags, tip | Rating with tags, tip, receipt by email |
| Receipt | Trip receipt page, PDF | In-app | In-app + email |

Recommendations:

- **Rating tags and tip** on the completion card: both references ask for
  a star rating with quick tags ("Clean car", "Great route") and a tip.
  `ride_rating_card.dart` has the stars; tags and a tip row are missing.
- **Apple Pay** through the gateway when cards are enabled; a native sheet
  beats a web-view checkout on iOS.
- **Cash booking shows "GET.wallet RM0.00 · Top up to use"** (finding #14)
  on the complete card; the references show only the method that was used.

## 9. Trips, wallet, account

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| History | Filter chips, two-line rows, "Not charged" | List by date, rebook | List by date, rebook, receipt, report issue |
| Rebook | — | "Repeat" on a past ride | "Rebook" on a past ride |
| Wallet | Balances, Scan & Pay, Receive, GET.coin trade, history with filters | Wallet (market-dependent) | GrabPay: balance, top up, Scan, rewards points |
| Account | Profile, referral, My Ride (favourite drivers via code), safety, settings, support | Profile, safety, settings | Profile, rewards, Grab for Family, settings |

Recommendations:

- **Rebook** from a trip row (swipe action or button on the receipt): both
  references have it and it is one `context.go('/')` with the stored
  pickup / drop.
- **Report an issue** from the trip row / receipt, linking to a pre-filled
  support ticket; Grab's single most used post-trip action.

## 10. Driver side

| | GET.ride | inDrive | Grab |
| --- | --- | --- | --- |
| Online | "You are online" toggle card, floating request cards on the map | Online toggle, request cards with fare, distance to pickup, rating; Accept / counter-offer | Online toggle, job card: fare, pickup distance, trip distance, countdown ring; Accept / auto-accept |
| Request | Service, fare, km · payment · pax, pickup, drop, "Accept for RM…", counter-offer sheet, 60-s alert with map | Same + rider rating | Same + countdown ring, destination sometimes hidden |
| Trip | Status title, passenger card (Call / Message), stops, "Start trip" / "Complete trip · collect RM…" footer, navigation hand-off | Similar | Similar + in-app navigation, read-aloud |

GET.ride is on par; its read-aloud toggle and counter-offer sheet are
ahead of Grab's defaults. Items from the findings list still apply: request
card contrast "Cash · 1 pax" 1.9:1 (#28), the compact call button label
(#27), landscape clipping (#44).

## 11. iOS platform fit

| | GET.ride | inDrive / Grab |
| --- | --- | --- |
| Back swipe | Blocked on Offer fare, in-app pages and wizard steps (#47) | Works everywhere |
| Dynamic Type | Capped at 1.3× (`maxAppTextScale`) | Grab follows system sizes on list screens |
| Dark mode | Full | Full |
| Live Activities | — | Grab: yes |
| Widgets / quick actions | — | Grab: yes |
| Haptics | Key events (accept, SOS, QR) | Yes |
| Sign in with Apple | — | Grab: yes |
| ProMotion | Enabled (`CADisableMinimumFrameDurationOnPhone`) | Yes |

The 1.3× cap is the one accessibility gap: iOS Accessibility sizes go to
3.1×. Raising the clamp on text-only pages (Trips, Settings, Help, receipts,
admin) while keeping 1.3× on the map sheets would honour the setting where
it matters without breaking the sheets.

## Priority list for the fixing session

1. "Raise your fare and search again" on the searching sheet (§5).
2. Plate-first driver card and ETA in the tracking title (§6).
3. One Safety sheet from the trip screen; trusted-contact auto-share (§7).
4. Rating tags + tip on trip completion; Rebook and Report from trips (§8, §9).
5. iOS: portrait lock on iPhone (closes #41–#45, #48, #52), quick actions,
   Live Activity, Sign in with Apple (§2, §6, §11).
6. "Where to?" above the vehicle chips on the home sheet (§2).
7. Gate / entrance choice and directions before the fare (§3).

Sources used for the reference apps: Grab product stories (Venues, pickup
guides, 5 booking tips), Grab press releases on Safety Centre, AudioProtect,
Trip Monitoring and GrabX 2026; inDrive help centre ("How fares are
calculated"), App Store listing and third-party walkthroughs (Out of Town
Blog, Trip Nexus, Medium product reviews). Where a detail could not be
confirmed from those (exact labels, timers), it is described as a pattern
rather than quoted.
