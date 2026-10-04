# GET.ride — Flutter

Flutter client for **GET.ride** that runs on **web, desktop (macOS / Windows / Linux), iOS and Android** from one codebase. It talks to the **same Supabase project** as the Expo app in [getgroupmy/get.ride](https://github.com/getgroupmy/get.ride), so accounts, rides, wallets and support chats are shared between both apps.

## Features

| Area | What works |
| --- | --- |
| Sign-in | Phone number → SMS OTP → 6-digit PIN. Returning users sign in with their PIN. Same contract as the Expo app (`profile_phone_lookup`, `verify_pin_for_login`, `set_login_pin`, PIN-derived Auth password), so a PIN set in either app works in both. |
| Ride booking | OpenStreetMap map, place search, choose-on-map, route + ETA, TEKSI fare calculation (ported from `utils/maps.ts`), service + payment choice, creates `ride_requests` rows and pings partners via the `send-push` edge function. |
| Ride tracking | Live status via Supabase Realtime, driver details + live position, trip code, call/SMS driver, cancel / cancellation-request flow. |
| Drive (partner) | Online toggle, live queue of open requests sorted by distance, race-safe accept, arrive → verify trip code → start → complete, live location publishing, commission charged via `wallet_charge_ride_commission` (rate resolution ported from `utils/commissionStore.ts`). |
| Wallet | GET.wallet / GET.coin / credit balances and transaction history (read-only; money movement stays behind the server RPCs). |
| Account | Profile edit, referral code, emergency contacts, support chat (realtime), light/dark theme, change PIN. |
| Layout | Bottom navigation on phones, navigation rail on tablets, extended rail + side-by-side map panels on desktop/web. |

Not ported yet (still Expo-only): partner onboarding & document upload, Meter Digital / OBD-II, EV orders, GET.coin trading, voice protection, push-notification registration.

## Admin panel (`lib/src/admin/`, route `/admin`)

Opened from **Account → Admin panel**, which only appears for accounts with at least one `admin_access` row. Access comes from the database only: the same rows `caller_is_admin()` checks in every RLS policy. There is no local admin password, unlike the Expo panel's hardcoded login. Page keys are the Expo route keys (`admin-users`, `admin-settings-promocode`, …, `*` for everything), so grants made in either app apply to both. On a brand-new project the first signed-in user can claim admin through `admin_access_bootstrap()`.

| Module | What it does |
| --- | --- |
| Dashboard | Live counts (users, partners awaiting approval, open/active rides, documents to review, open tickets), each linking to its list. |
| Users | Search and filter (approved / unapproved / ID failed / blocked / rejected / deleted), details, set account status. |
| Partners / Vehicles | Search and filter including permit states, details, set status, set permit, mark documents complete. |
| Documents | Partner and vehicle documents: review queue, open front/back files, AI verification details, approve or reject with notes. Expiry is shown as `Expired`. |
| Rides | Monitor open, in-progress, completed and cancelled requests, view full details, cancel a ride. |
| Support | Ticket pool (active / unassigned / mine / resolved), realtime chat as admin, assign to me, change status. |
| Push notifications | Broadcast to everyone, passengers or partners via `send-push`, plus send history. |
| Commission rates | Create, edit and delete master/country/state/city/suburb/user rules. |
| Settings | All 23 Expo CRUD categories, generated from the Expo screens into `admin_categories.g.dart`, including the insurance provider → type → duration → premium drill-down and ordering. Any other `settings_entries` category gets an advanced raw-JSON editor. |
| Sub-admins | Grant per-page read/edit access by phone number, revoke grants. |

Every other Expo admin screen is ported under `/admin/m/…` and listed on the **Settings** hub by section (`lib/src/admin/screens/<group>/`):

| Section | Screens |
| --- | --- |
| People | Add/edit partners and vehicles (photos, documents, service areas), edit users, user ID-document review |
| Services & catalogue | Services, vehicle services, partner types (icons), document types, required documents, vehicle makes & models, service assignment |
| Payments & commerce | Payment types, payment gateways (public fields only; see security notes), GET.coin, EV order fee / finance options / vehicle details / inventory, EV orders back office |
| Geography | Countries/states/cities with geofences, airport areas, multi-gate places and gates (OpenStreetMap search and polygon editing) |
| Meter & app | Meter Digital rate cards (scoped, live panel switches), display and mock settings, site, app icon, splash, always-on pages |
| Security & integrations | Session history with trails/heatmap, fraud tracing, IP access rules, API keys (masked), eLife, fare AI and its logs, read-only backend diagnostics |

Intentionally not ported: user *add* (a profile needs an auth account), Rork chat (Expo/Rork-specific, ships a toolkit secret), the Expo backend screen's runtime URL/service-role-key entry, installed-app detection, and any client-side handling of secrets.

## Run

```bash
flutter pub get
flutter run -d chrome        # web
flutter run -d macos         # or windows / linux
flutter run -d <device-id>   # iOS / Android
```

## Configuration

Defaults point at the production Supabase project used by the Expo app. Override per build with `--dart-define`:

| Key | Default |
| --- | --- |
| `SUPABASE_URL` | `https://rqlavogkgywxspuxgiwk.supabase.co` |
| `SUPABASE_ANON_KEY` | the Expo app's public anon key |
| `CURRENCY` | `MYR` |
| `DIAL_CODE` | `+60` |
| `NOMINATIM_URL` / `OSRM_URL` | public OpenStreetMap endpoints (use self-hosted ones in production — the public servers have strict usage limits) |
| `GEO_COUNTRIES` | `my` |

Only ever ship the **anon** key; all access is enforced by the database's RLS policies.

## Build

```bash
flutter build web --release --no-web-resources-cdn
flutter build apk --release          # Android
flutter build ipa                     # iOS (needs signing)
flutter build macos | windows | linux
```

CI (`.github/workflows/flutter.yml`) analyses, tests and builds every platform.

## Deploy (web → Vercel)

`.github/workflows/deploy-web.yml` builds the web app and uploads it to Vercel: **production** on every push to `main`, a **preview** for each pull request (its URL is posted as a PR comment). Vercel has no Flutter builder, so the site is built in GitHub Actions and shipped prebuilt (`vercel deploy --prebuilt`); every unknown path falls back to `index.html` so deep links reach the router.

One-time setup:

1. In Vercel, create a project (Add New → Project; import this repo, or create an empty one). The workflow uploads a finished build, so the project's framework/build settings don't matter. If you did import the repo, turn off Vercel's own Git deployments for it (Settings → Git) so each push isn't deployed twice.
2. Create a token under Account Settings → Tokens.
3. Add three repository secrets (GitHub → Settings → Secrets and variables → Actions):
   - `VERCEL_TOKEN` — the token from step 2
   - `VERCEL_ORG_ID` — the team/account ID (Vercel → Settings → General)
   - `VERCEL_PROJECT_ID` — the project ID (project → Settings → General)

Web Analytics and Speed Insights are wired into `web/index.html` as Vercel's script tags (the non-npm forms of `@vercel/analytics` and `@vercel/speed-insights`); turn each on in the project's **Analytics** / **Speed Insights** tab and it starts reporting from the next deploy. The app uses Flutter's default hash URLs (`/#/route`), so Analytics is likely to group every screen under `/`; per-screen numbers would need the path URL strategy.

Until all three are set, the workflow skips the deploy and leaves a notice instead of failing. It can also be run by hand from the Actions tab (**Run workflow**), which deploys `main` to production and any other branch as a preview.

## Layout

```
lib/
  main.dart
  src/
    config.dart          build-time configuration
    app.dart             theme + router (auth redirects)
    providers.dart       Riverpod providers
    core/                pure logic ported from the Expo app (auth, fare, commission, formatting)
    data/                Supabase repositories, models, geocoding/routing
    features/            auth, ride, partner, wallet, profile, support, settings, shell
    widgets/             shared widgets (map, empty states, code field)
test/                    unit + widget tests
```
