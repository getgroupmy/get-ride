# KIV (keep in view)

Items the owner has parked. Remove an item in the same PR that ships it.

## Services, partner types and vehicle services (study of 26 Oct 2026)

Low:

(M3, the list's quick Approve, and L3, the step count, are in the partner review fixes.)

## APAD / SPAD e-hailing guideline (study of 31 Oct 2026)

Checked against SPAD Garis Panduan Bil. 2 Tahun 2018 (e-hailing under an LPP licence). Confirm each against APAD's current rules before building.

Conflicts:

- 8.1 Street hailing: private e-hailing cars may take app bookings only. myGiG lets any driver who isn't TEKSI take street-hail rides, and its hotspots show where passengers wave. Owner to decide: limit myGiG to taxi, rental car and limousine, or keep it as is.
- 8.3 No bargaining after booking: bidding happens before matching, but drivers can counter and riders can raise up to 4x the quote. Limit bids to the surcharge cap below and keep the fare fixed once matched.
- 9.3 Surcharges: at most 2x the base fare. Region charges, place fees, the meter night rate and myGiG busy times have no cap on their total. Add one server cap (an admin setting, 2x at most).
- 9.6 Commission: at most 20% for e-hailing and 10% for taxi, rental car and limousine. Today any rate from 0 to 99.99% can be set, and the 15% default also applies to taxis. Keep rates dynamic (driver, area, service, tiers, promotions) under a per-class ceiling (an admin setting, 20% / 10% at most), myGiG fees included.
- 6.2 Vehicle age: the guideline says 10 years (licence age 9, CKD from JPJ registration, CBU from year made); the document check uses 15. Per-class limits with a CKD/CBU field, defaults per APAD's current rule.

Missing or partly built:

- 5.1b PDPA consent tick at sign-up, stored with the time.
- 5.2 Passenger full name and IC (passport for foreigners), masked; owner to decide whether at sign-up or before the first booking.
- 5.1g / 9.5 Driver's PSV / e-hailing driver card number and expiry shown to riders and on the receipt and PDF; required from e-hailing drivers.
- 5.1h SOS as one action (call 999, alert operations and text the emergency contacts together), also on City to City and the TEKSI meter screen.
- 9.4 E-receipt sent to the rider at trip end (email or push), not only downloadable.
- 10.1 E-hailing insurance required, checked on the server (the online check runs only in the app today and lets drivers through when it can't read the documents).
- 6.2 Vehicle fields and checks: NCAP 3-star, doors and body type, 4 to 11 seats, colour rules, yearly PUSPAKOM after 3 years, JPJ e-hailing sticker.
  - Shipped: the vehicle ownership certificate (VOC / geran) is a compulsory vehicle document (0388) and a hard gate — uploaded to submit, verified (an approver's Approved) to approve a vehicle, blocking refusable with an admin reason; legacy-exempt, with the soft "missing VOC" badge (0392, 0402). The rest of this 6.2 line (NCAP, body/doors, seat range, colour, PUSPAKOM, JPJ sticker) is still open.
- 11.1 Permit check: off for Malaysia today (3-day grace when on); drivers without a valid eVP can go online.
- 7.5b Airports: only drivers who dropped off may pick up. The queue exists (0249) and is on for KUL, BKI and KBR, but "must have dropped off" is off there; the owner wants no restriction for now, with the option kept.
- 7.1 Peninsular Malaysia only, and taxis returning to their home area: region settings only, nothing enforced.
- 11.4 Driver code of conduct and a driver grievance and appeal process.
- 11.5 Data export or reports for APAD and other agencies.

## Live tracking after the app is closed (study of 11 Nov 2026)

Goal: keep a trip's live map dot moving when a participant swipes the app away, for users on "Always"/"Allow all the time". "Always" is a permission for a *running* app to read location in the background — it does not keep a killed app alive, so the geolocator stream (and the dot) dies on swipe-away. The native background reporter (0272) and God View live stream (0282) already keep reporting with no app running, keyed by the install's background key.

- Shipped (slice 1, 0404): `trip_live_bridge` — a background/live fix from a phone whose account is a participant in an active ride (`accepted`/`arrived`/`on_trip`) also refreshes that ride's live columns (the rider's `user_live_*`, the driver's `partner_live_*`). Wired into `push_background_location` and `push_live_location`. Same two columns, same two recipients, same purpose the app already shares them for — just kept fresh while the app is closed. No new build needed. Cadence is coarse, though: the background path reports ~once a minute at most and the native reporter's own schedule is ~15 min / 200 m, so a closed-app dot only refreshes at that rate unless a 5-second live stream is open.
- Shipped (slice 2, 0405): the continuous cadence, reusing God View's "Live now" transport with no native change. `push_live_location` keeps answering `live:true` (`trip:true`) while the poster is on an active ride (gated by `background_checkin_allowed`, same as the background path), so a phone already streaming the 5-second stream carries on for the whole trip and stops on its own when the ride ends. `trip_live_kick()` (pg_cron `trip-live-kick`, every minute) wakes a closed/backgrounded phone whose active-trip fix has gone stale (> 45 s) by claiming its phones and sending a `location_live` push (`location_ping_kick`) — the native side starts its stream on that push with no God View session needed. Only fires for a killed app (an open or backgrounded-alive app keeps the fix fresh), throttled to one wake a minute a phone.
- Slice 3 (app + testing, not built): arm/`goLive` the reporter on trip start for both rider and driver so the stream starts without waiting for the first stale-fix kick; trip-appropriate "we keep sharing while the app is closed" copy/consent (the iOS `NSLocationAlwaysAndWhenInUse` string already says this); and the **device test matrix** — the one thing that can confirm the push actually wakes a terminated app and streams, which the server slices cannot.
- Hard ceilings to set expectations on (no app escapes these): iOS **manual force-quit** (swipe up in the app switcher) suppresses significant-change / push relaunch until the next reboot, so live-after-close is unreliable after a deliberate force-quit (works when iOS itself terminates the app, or it's only backgrounded). Aggressive Android OEMs (Xiaomi/Oppo/Vivo/Huawei) kill even foreground services; needs battery-optimisation allow-listing and per-OEM autostart guidance. "Live after close" therefore means *re-acquired within a push/SLC cycle*, never guaranteed-continuous.

## Owner setup

- Online payment: wallet top-up through the payment gateway is built (Fiuu, Billplz; FPX and e-wallets). Add the merchant account keys in Admin › Payment gateways, then turn Card back on. DuitNow QR top-up is not built.
- AI Reports email: add the Resend key in Admin › Settings › API Keys (Email › Resend) and verify the getride.my domain in Resend. Until then scheduled report emails don't send; downloads work.
- Sign-in checks face match, AWS Rekognition (later): add the key in Admin › Settings › API Keys (Amazon Web Services › Rekognition) as `ACCESS_KEY_ID:SECRET_ACCESS_KEY` (or add `:region`), an IAM user allowed `rekognition:CompareFaces` and `rekognition:ListCollections` only. Until then Admin › Documents › Sign-in checks shows "Not checked · No AWS key yet". AWS is the default in Admin › Dispatch › Accounts › Face match.
- Sign-in checks face match, self-hosted server (later): run `deploy/face-server` on the Synology NAS behind a Cloudflare Tunnel (face.getride.my), then add it in API Keys (Face match server) and pick Self-hosted server or Self-hosted, then AWS. Steps in [deploy/face-server/README.md](../deploy/face-server/README.md).
- Office NAS backups and uptime: deploy the `nas-ops` and `uptime-check` functions (`--no-verify-jwt`) and apply migration 0318, then run `deploy/nas-backup` on the NAS (connection code from Admin › Settings › Office NAS, the database connection string and the storage service key in its `.env`, the encryption key printed once at setup: keep it), set up Hyper Backup to Backblaze B2 or Synology C2, and turn on the alert channels (a Telegram bot token in API Keys › Telegram › Bot, the Resend key for email). Steps in [deploy/nas-backup/README.md](../deploy/nas-backup/README.md).
- Sign-in checks ID reading, Google Cloud Vision (optional): enable Cloud Vision API in a Google Cloud project with billing, make an API key kept to that API, add it in API Keys (Google › Cloud Vision (ID reading)) and test it, then switch Google Vision on in Admin › Dispatch › Accounts › ID card reading (the order: Phone, then NAS, then Google Vision). First 1,000 reads a month are free. Deploy the `id-read` function and apply migration 0283 first.
- Test database on the NAS (later): run `deploy/nas-testdb` (a read-only database user, a read-only GitHub token, a code from Admin › Settings › Office NAS › Test database), deploy the `nas-testdb` function (`--no-verify-jwt`) and apply migration 0321. Steps in [deploy/nas-testdb/README.md](../deploy/nas-testdb/README.md).
- Visitor stats on the NAS (later): run `deploy/nas-stats` (Umami) behind a Cloudflare Tunnel at stats.getride.my, add the Umami key in API Keys and the website ID in Admin › Settings › Office NAS › Visitor stats, deploy the `nas-stats` function, then set the STATS_SCRIPT_URL and STATS_WEBSITE_ID repository variables. Steps in [deploy/nas-stats/README.md](../deploy/nas-stats/README.md).

