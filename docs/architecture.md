# Architecture

How GET.ride is put together, and why it has (almost) no servers to run.

## One sentence

A **Flutter** client talks **directly** to a **Supabase** project (managed
Postgres + edge functions + storage + realtime); all the business logic lives
in the database as RLS policies, `SECURITY DEFINER` RPCs and triggers; the web
build is served by **Vercel** and fronted by **Cloudflare Workers**; releases
run on **GitHub Actions**. There is no application server to provision, patch or
scale. Two optional, self-hosted boxes (an office NAS and an SMS gateway) are
the only non-serverless parts, and both are fallbacks, not dependencies.

## Is it serverless?

At the core, yes — there is no middle-tier API server and nothing you keep
running for the app itself. Compute is either on the client, in the database,
or in on-demand functions.

| Concern | Where it runs | Managed by |
|---|---|---|
| UI, most app logic | Flutter client (iOS / Android / web / desktop) | the device / browser |
| Data + business rules | Supabase Postgres: RLS, RPCs, triggers | Supabase (managed) |
| Background / privileged work | Supabase Edge Functions (Deno, on-demand) | Supabase (managed) |
| File storage | Supabase Storage buckets | Supabase (managed) |
| Live updates | Supabase Realtime | Supabase (managed) |
| Web hosting | Vercel (prebuilt Flutter web) | Vercel (managed) |
| Subdomain / session routing | Cloudflare Workers | Cloudflare (managed) |
| Build / test / release / deploy | GitHub Actions (ephemeral runners) | GitHub (managed) |
| **Optional:** own maps, ID/face match, DB backups | **Office NAS (self-hosted)** | the operator |
| **Optional:** SMS / OTP fallback | **Messaging gateway (self-hosted)** | the operator |

So: no VM or container you own is required to run GET.ride. The two
self-hosted pieces are optional accelerators/fallbacks (see below).

## Client

- **Flutter** app (`lib/src/`), one codebase for iOS, Android, web and desktop.
  Riverpod for state; GoRouter for navigation. See the repository `CLAUDE.md`
  for module conventions.
- There is **no client-side API layer of our own** — screens and
  `utils/*Store`-style repositories call Supabase (`supabase_flutter`)
  directly, and the database's RLS is the real gate.
- The earlier **Expo / React Native** app (`getgroupmy/get.ride`) was retired;
  both apps were written against this same backend, so `docs/backend.md` still
  names Expo paths where it describes client behaviour — the Flutter
  equivalents are under `lib/src/`.

## Backend — Supabase (the "server" that isn't one)

Everything in [`supabase/`](../supabase); full notes in
[`docs/backend.md`](./backend.md).

- **Managed Postgres** is the backend. Business logic is in the database:
  - **RLS policies** on every table — clients can only read/write what
    `auth.uid()` / `caller_is_admin()` allow.
  - **`SECURITY DEFINER` RPCs** for every privileged or balance-changing
    operation (wallets, commission, partner approval, per-service enablement,
    lawful export, …), each asserting the caller.
  - **Triggers** for dispatch rules, push webhooks (`pg_net`), registration
    rules, etc.
  - Schema in `supabase/schema.sql`; numbered migrations in
    `supabase/migrations/` (from the `0097` squashed baseline). CI's
    *Migrations replay* job rebuilds a fresh DB from the folder and runs
    `supabase/tests/*.sql`. Migrations reach the live project with
    `supabase db push`, **run by a person after merge, never automatically**.
- **Edge Functions** (Deno) for work that can't live in the DB or needs a
  secret: `send-push`, `ip-lookup`, the `android-release` / `ios-release`
  dispatchers, etc. On-demand; nothing to keep warm.
- **Storage** buckets (`provider-documents`, `vehicle-documents`, …) with
  owner/admin RLS.
- **Realtime** drives live ride dispatch, admin live-data, and location
  sharing.

Representative flows, all client → Postgres (no app server in the middle):

- **Ride dispatch** — rider inserts an `open` `ride_requests` row; a trigger
  fires `send-push`; online partners subscribe via Realtime, accept (claim)
  and progress the row; per-service dispatch is gated server-side by
  `driver_partner_service_ok` (see per-service enablement, migration `0339`).
- **Wallets / commission** — balances are ledger-driven; every change goes
  through an owner-scoped `SECURITY DEFINER` RPC.
- **Auth** — Supabase phone-OTP is primary; a legacy local-PIN path is the
  offline fallback.

## Edge & hosting

- **Vercel** serves the Flutter **web** build. Vercel has no Flutter builder,
  so `deploy-web.yml` builds the site in CI and uploads it with the Build
  Output API (`vercel deploy --prebuilt`); Vercel only serves it. On a push to
  `main` that passes checks it deploys production; other branches get a
  preview. See [`docs/store-release.md`](./store-release.md) → App links.
- **Cloudflare Workers** (`cloudflare/subdomain-proxy`, `cloudflare/session-proxy`)
  answer any `*.getride.my` subdomain (e.g. `qr.getride.my` for My QR codes) by
  fetching from the production host and serving it under the visitor's
  subdomain. Deployed by `cloudflare-worker.yml`.

## CI / CD & release

GitHub Actions (`.github/workflows/`), all on ephemeral runners:

- **Flutter** (`flutter.yml`) — on every PR and push to `main`:
  `flutter analyze` (zero-tolerance), `bunx`/`deno` checks, `flutter test`,
  plus *Migrations replay*, *Migration numbers*, *Edge-function tests*,
  *security-review*, *release-scripts*, and the per-platform builds. A green
  push to `main` triggers the web deploy.
- **Deploy web** (`deploy-web.yml`) → Vercel.
- **Android release** (`android-release.yml`) → Google Play (track selectable:
  internal / alpha / beta / production) + an `android-latest` APK GitHub
  release. Dispatched by hand or by the admin console via the `android-release`
  edge function.
- **iOS release** (`ios-release.yml`) → App Store Connect (`testflight` or
  `appstore`), on a macOS runner.
- **Backend** (`backend.yml`), **Cloudflare worker**, **Gateway app**,
  **Sync map keys**, **Security review** workflows round it out.

Release details and the required secrets are in
[`docs/store-release.md`](./store-release.md).

## Optional self-hosted components (the non-serverless parts)

Neither is required; both fall back to a cloud path when absent.

- **Office NAS** (a Synology box) — can host, as alternate providers ahead of
  the cloud: own maps (routes / search / web map before Google), ID reading
  and face match (a free first pass before a paid cloud check), nightly DB
  backups with a restore test, and a test copy of the database + visitor
  stats. Surfaced under Admin › Settings › Office NAS. See
  [`docs/NAS.md`](./NAS.md).
- **Messaging gateway** (`gateway.yml`, the "Gateway app") — a self-hosted
  device that can send SMS / OTP as a fallback to the cloud SMS path.

## Security model (summary)

- The database is the gate: **RLS on every table**, privileged work only
  through **owner/admin-scoped `SECURITY DEFINER` RPCs**, admin access via
  `caller_is_admin()` / page-scoped rules, and IP allow/deny
  (`ip_access_rules`).
- No service-role key ships in the client; edge functions hold the few secrets
  that exist.
- Office-network / Claude access rules and the lawful-request export
  (`docs/lawful_requests.md`) are admin-only and audit-logged.

## See also

- [`docs/backend.md`](./backend.md) — the database, migrations, edge functions.
- [`docs/store-release.md`](./store-release.md) — building and shipping the apps.
- [`docs/NAS.md`](./NAS.md) — what the office NAS can host.
- [`docs/session-access.md`](./session-access.md), [`docs/device-attestation.md`](./device-attestation.md),
  [`docs/passkeys.md`](./passkeys.md) — auth/session hardening.
- The repository `CLAUDE.md` — client module conventions.
