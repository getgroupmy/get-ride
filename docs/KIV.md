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
- What to expect per platform (the real limit is cadence, not that it dies): **iOS does keep getting location after the app is swiped away.** `BackgroundLocationReporter` (`AppDelegate.swift`) registers significant-location-change monitoring, visit monitoring and a 200 m geofence (region monitoring) — all three of which relaunch a terminated app in the background, the relaunch path wired through `resumeIfArmed()`. So after a swipe-away the dot un-freezes and tracks as the car moves, at a **coarse, event-driven cadence** (~200 m geofence exit / ~500 m SLC / visits), chaining into a short 5 s burst when a relaunch triggers the `location_live` kick — not a smooth continuous stream, and it needs "Always". (An earlier note here wrongly said a manual force-quit suppresses relaunch until reboot; region and visit monitoring relaunch even after a deliberate swipe-away, so that was wrong.) On **Android**, aggressive OEMs (Xiaomi/Oppo/Vivo/Huawei) can kill even foreground services, so reliability there wants the battery-optimisation exemption (the nudge in #675) and per-OEM autostart guidance. "Live after close" therefore means *re-acquired within a push/SLC/geofence cycle*, never guaranteed-continuous.

## GET.support — AI self-answering customer care (study of 15 Nov 2026)

Goal: an AI assistant that answers riders, partners and general enquiries like a human agent, by
**chat and voice**, with **human handoff** and a **saved both-party transcript**, in **8 languages** —
English, Bahasa Malaysia, Tamil, Punjabi, Hindi, Chinese (Malaysian Mandarin), Nepali, Bengali. Branded
**GET.support**. Interactive UI mockup and a plan/flow page were prepared for the owner (private claude.ai
artifacts). Not built — parked for the owner.

Decisions made:

- **No paid AI.** The whole stack is open-source / self-hosted: LLM = Llama 3.3 / Qwen2.5 (Qwen is
  stronger on Chinese + Asian languages) via **Ollama/MLX**; STT = **Whisper** (or Vosk / the phone's
  built-in recogniser); TTS = **Piper** / Coqui / the phone's built-in engine. The app only ever calls
  *our own* edge function, which calls *our own* model host, so the model is swappable without touching
  the app. Only cost is hosting, no per-message AI fee. Bigger models give better Tamil/Punjabi/Nepali/
  Bengali.
- **Surface: upgrade the existing Help assistant**, not a new screen. `HelpAssistantScreen` (`/account/help`,
  reached from Account › Help & support and the side menus) becomes AI-powered; keep the article/KB search
  as grounding *and* as the graceful fallback when the AI is off or unreachable, plus the existing
  escalation to the human ticket (`helpSupportRoute` = `/account/support`) and the thumbs feedback /
  question log. Reuses the route, so **no new page-inventory id to regenerate**. Add a GET.support menu
  tile (admin menu config) pointing at it.
- **Grounded + guardrailed.** Edge function mirrors the `vehicle-catalog-lookup` pattern (Bearer auth,
  `auth_rate_take` limiter, CORS/JSON helpers) but points at the self-hosted model instead of Gemini.
  Grounds on the help KB (reuse the `help_search` RPC) + an app-knowledge system prompt; never invents
  policy; replies in the user's language (auto-detected or picked).
- **Personalised (own data only).** May read the signed-in user's *own* rides / wallet / tickets via
  owner-scoped RPCs to answer "where's my driver", "my last fare" — never another user's data.
- **Languages.** Auto-detect + an 8-language picker, saved as a `preferred_language` profile field
  (model it on the `profiles.nationality` country-resolution pattern). No i18n framework exists today, so
  this is net-new; reply language is handled in-prompt.
- **Transcripts.** Store both sides (user + AI, and the voice turns) in a new `support_conversations`
  table, same access rules as support tickets — visible to the user and to admin.

Phases: A text AI → B personalised → C languages → D in-app voice → E phone line → F admin (enable/
disable AI & voice, edit the knowledge base, pick model/voice/languages, review transcripts; reuse the
Help admin module). A–C are ordinary app + edge-function work; D and E are the larger native/infra pieces.
Optional bonus: an **AI SMS/WhatsApp** channel on the owner's existing SMS-gateway device (normal app
APIs, no special privilege).

Phase D (in-app voice): talk to GET.support like a normal call — realtime listen→answer→speak with a live
saved transcript, on the existing `support/call` stack. Self-hosted/on-device STT + TTS; needs a new
native build.

Phase E (phone line) — hardware **decided**, using the owner's own kit:

- The owner's **ZTE MC801A** 5G router has an **RJ11 "Tel" port** (VoLTE telephony on the SIM). A data-only
  modem could not do this; the Tel port is what makes it possible. The MC801A can't capture/inject call
  audio itself, and stock/debugged (ADB/Shizuku) Android can't either — call audio is a privileged/root-only
  capability (unlike SMS, which is a normal-app API, which is why the SMS gateway works and a voice gateway
  app would not).
- Bridge: **MC801A Tel (FXS) → Grandstream HT813 FXO "Line" port → SIP → Asterisk/FreeSWITCH → Whisper /
  LLM / Piper → spoken back into the call → transcript saved → human transfer on request.** The HT813
  (~US$50, network FXO ATA on the LAN) is the **only** hardware to add; the SIM stays in the router, no
  root, no APK, no call-forwarding. Configure FXO **disconnect detection** and **caller-ID (FSK) capture**.
- Pre-flight test (no hardware): plug an ordinary analog phone into the MC801A Tel jack and call the SIM's
  number — if it rings and two-way audio works, VoLTE voice is live and the bridge will work; if not, the
  SIM's voice/VoLTE must be enabled on the plan first.
- Deployment: run the whole stack (Asterisk + Whisper + Piper + LLM via Ollama/MLX) on a **Mac mini M4
  (24 GB recommended)** — Apple Silicon handles a 7–14B model at near-conversational latency for live
  calls. The **DS224+** (Celeron J4125, ≤ 6 GB) is fine for Asterisk + small Whisper/Piper but **too weak
  for a snappy live-voice LLM**, so keep it for storage, backups and transcript/recording archive rather
  than the brain. (Synology DSM can't load DAHDI drivers, which is another reason the bridge is a *network*
  FXO ATA, not an internal/USB card.)

## iOS UI/UX testing (paused 19 Oct 2026)

A tester session rendered every screen as an iPhone would show it and sent each problem to the fixing session. Paused by the owner; the work is on the branch `claude/bold-rubin-s8wiu3` (not merged), so pick it up from there.

- Where it is: [docs/ios-ux-findings.md](ios-ux-findings.md) lists findings 1 to 57 with file references and status; [docs/ios-ux-benchmark.md](ios-ux-benchmark.md) compares GET.ride with inDrive and Grab and ends with a priority list for the owner; [docs/app-review-calls-video.md](app-review-calls-video.md) is the shot list and App Review notes for the in-app calls video. The screenshot harness is `test/ios_shots_test.dart` (does nothing unless `SHOTS_DIR` is set).
- Last full check: head 80c624b (18 Oct 2026). The next head, 65c6659 (19 Oct, with the landscape and sheet-height fixes of #431), was not checked before the pause, and a month of changes has landed since, so re-check before acting on anything below.
- Open then: #28 muted text below AA contrast; #45 phone and code screens in landscape with the keyboard (title behind the bar); #52 Options sheet, Add a driver sheet and admin Vehicle Types in landscape; #53 Offer your fare opens at "RM 68" against a RM68.05 recommended fare; #54 map buttons clipped by the ride sheet in landscape; #55 and #56 the driver's ride-request alert in landscape (no fare or addresses shown, markers drawn three times); #57 confirm card clipped in landscape at large text.
- Owner decisions from the benchmark: "raise your fare and search again" when no offers come, plate-first driver card with the ETA, one Safety sheet with trusted-contact auto-share, rating tags and tip, Rebook and Report from trips, iPhone portrait lock, home-screen quick actions, a Live Activity for the ride, Sign in with Apple.
- App Review calls video: needs two real iPhones with the TestFlight build (a cloud session cannot record one). Check first that the build signs with production push and that VoIP pushes go to production APNs.
- To resume, start a session on this repository with: "Read docs/ios-ux-findings.md on claude/bold-rubin-s8wiu3, rebase it onto main, run test/ios_shots_test.dart with SHOTS_DIR set (and LAND=1 for landscape), and report which open findings are fixed."

## Follow-ups (23 Nov 2026)

- My Team on a phone (0432): for an approved member, an approver who is not an admin sees "This member is approved, so an admin changes their services." in place of the Courier toggle, and the services read-only in the profile edit sheet. Checked by widget tests only; look at it on a phone once the next app build is out.
- Supabase CLI 4 (before upgrading, not urgent): rename `auth.email.enable_signup` and `auth.sms.enable_signup` in `supabase/config.toml` and move CI's local build (`.github/workflows/backend.yml`, CLI 2.119.0) to CLI 3, together. CLI 3's `auth.email.enabled` / `auth.sms.enabled` switch the whole provider on or off (new sign-ups are blocked with `[auth] enable_signup`), so keep phone sign-in on for the local stack. The deploy steps in [supabase/README.md](../supabase/README.md) pin `npx supabase@3` until then.

## Owner setup

- Online payment: wallet top-up through the payment gateway is built (Fiuu, Billplz; FPX and e-wallets). Add the merchant account keys in Admin › Payment gateways, then turn Card back on. DuitNow QR top-up is not built.
- AI Reports email: add the Resend key in Admin › Settings › API Keys (Email › Resend) and verify the getride.my domain in Resend. Until then scheduled report emails don't send; downloads work.
- Sign-in checks face match, AWS Rekognition (later): add the key in Admin › Settings › API Keys (Amazon Web Services › Rekognition) as `ACCESS_KEY_ID:SECRET_ACCESS_KEY` (or add `:region`), an IAM user allowed `rekognition:CompareFaces` and `rekognition:ListCollections` only. Until then Admin › Documents › Sign-in checks shows "Not checked · No AWS key yet". AWS is the default in Admin › Dispatch › Accounts › Face match.
- Sign-in checks face match, self-hosted server (later): run `deploy/face-server` on the Synology NAS behind a Cloudflare Tunnel (face.getride.my), then add it in API Keys (Face match server) and pick Self-hosted server or Self-hosted, then AWS. Steps in [deploy/face-server/README.md](../deploy/face-server/README.md).
- Office NAS backups and uptime: deploy the `nas-ops` and `uptime-check` functions (`--no-verify-jwt`) and apply migration 0318, then run `deploy/nas-backup` on the NAS (connection code from Admin › Settings › Office NAS, the database connection string and the storage service key in its `.env`, the encryption key printed once at setup: keep it), set up Hyper Backup to Backblaze B2 or Synology C2, and turn on the alert channels (a Telegram bot token in API Keys › Telegram › Bot, the Resend key for email). Steps in [deploy/nas-backup/README.md](../deploy/nas-backup/README.md).
- Sign-in checks ID reading, Google Cloud Vision (optional): enable Cloud Vision API in a Google Cloud project with billing, make an API key kept to that API, add it in API Keys (Google › Cloud Vision (ID reading)) and test it, then switch Google Vision on in Admin › Dispatch › Accounts › ID card reading (the order: Phone, then NAS, then Google Vision). First 1,000 reads a month are free. Deploy the `id-read` function and apply migration 0283 first.
- Test database on the NAS (later): run `deploy/nas-testdb` (a read-only database user, a read-only GitHub token, a code from Admin › Settings › Office NAS › Test database), deploy the `nas-testdb` function (`--no-verify-jwt`) and apply migration 0321. Steps in [deploy/nas-testdb/README.md](../deploy/nas-testdb/README.md).
- Visitor stats on the NAS (later): run `deploy/nas-stats` (Umami) behind a Cloudflare Tunnel at stats.getride.my, add the Umami key in API Keys and the website ID in Admin › Settings › Office NAS › Visitor stats, deploy the `nas-stats` function, then set the STATS_SCRIPT_URL and STATS_WEBSITE_ID repository variables. Steps in [deploy/nas-stats/README.md](../deploy/nas-stats/README.md).
- Google map keys sync (GitHub › Actions › Sync map keys, monthly on the 1st and by hand): the `SUPABASE_ACCESS_TOKEN` repository secret was refused as an invalid access token on 1 Nov 2026, so the copy of the Google keys to the `geo` function's secrets fails. Create a personal access token in Supabase (Account › Access Tokens), save it as that secret in GitHub › Settings › Secrets and variables › Actions, then run the workflow once by hand. The next scheduled run is 1 Dec 2026.

