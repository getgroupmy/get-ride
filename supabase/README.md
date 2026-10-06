# Supabase setup

Everything needed to bring up a brand-new Supabase project for this app.

## Files

| File         | Purpose                                                          |
| ------------ | ---------------------------------------------------------------- |
| `schema.sql` | Tables, enums, triggers, RLS policies, storage buckets. Idempotent. |
| `seed.sql`   | Default settings entries + app settings, matching in-app defaults. |
| `reset.sql`  | Destructive teardown (keeps storage buckets).                    |
| `setup.sh`   | One-shot bootstrap script (`psql` wrapper).                      |
| `config.toml` | Supabase CLI config (`supabase link` / `supabase db push`).     |
| `migrations/` | Numbered migrations, starting from the `0098` squashed baseline; `supabase db push` applies the new ones. |
| `migrations_archive/` | The 101 migrations (`0001`–`0097`) the baseline replaced. History only: nothing reads them. |
| `baseline-migration-history.sh` | Marks every migration as applied in the database's history (see below). |
| `check-migration-numbers.sh` | CI check: unique, well-named migration versions.       |

## Quick start (cloning into a new Supabase project)

1. Create a new project at https://supabase.com.
2. Copy the **Connection string (URI)** from *Project Settings → Database*.
3. Run:

   ```bash
   export SUPABASE_DB_URL="postgres://postgres:PASSWORD@db.REF.supabase.co:5432/postgres"
   ./supabase/setup.sh
   ```

4. In *Project Settings → API*, copy:
   - `Project URL` → `EXPO_PUBLIC_SUPABASE_URL`
   - `anon public` key → `EXPO_PUBLIC_SUPABASE_ANON_KEY`

5. Restart the app — it now points at the new project with the same baseline data.

### No `psql`? Use the Dashboard

Open *SQL Editor* in Supabase and paste, in order:
1. `schema.sql`
2. `seed.sql`

Storage buckets are created automatically by `schema.sql`.

A project set up this way has no migration history yet, so before its first
`supabase db push` run `./supabase/baseline-migration-history.sh` (setup.sh
does this for you).

## Deploying migrations

Migrations reach a live project with the Supabase CLI. Nothing deploys
automatically: a person runs `db push`.

**One-time setup per machine**, from a clone of this repo (the live GET.ride
project is `rqlavogkgywxspuxgiwk`):

```bash
npx supabase login
npx supabase link --project-ref rqlavogkgywxspuxgiwk
```

The commands in this section have no trailing `# comments`: zsh passes them
to the CLI as arguments unless `interactive_comments` is set.

**The 0098 squash (one-time, right after it merges).** `migrations/` now
starts from one squashed baseline, `0098_squashed_baseline.sql` (a copy of
`schema.sql` at the time), because Supabase preview branches and
`supabase db reset` build a fresh database by replaying `migrations/` and the
old 101-file chain could not do that. Existing databases already contain
everything in it, so it must be recorded as applied, never run. After merging,
from an up-to-date `main`:

```bash
export SUPABASE_DB_URL="postgres://postgres:PASSWORD@db.REF.supabase.co:5432/postgres"
./supabase/baseline-migration-history.sh
npx supabase db push --dry-run
```

The script removes the `0001`–`0097` history rows and records `0098`; the dry
run should then report nothing to push. Before merging, check that the GitHub
integration's **Deploy to production** option is off (Project Settings →
Integrations): if it is on, the merge itself would try to apply `0098` to
production. Preview branches additionally need **Automatic branching** turned
on there, with the working directory set to `.`.

**Baseline.** The live project was baselined on 2026-10-05 (and again for the
0098 squash): its history holds exactly the files in `migrations/`. A project whose history is out of step
(hand-applied migrations, or one bootstrapped from `schema.sql`) is lined up
with:

```bash
export SUPABASE_DB_URL="postgres://postgres:PASSWORD@db.REF.supabase.co:5432/postgres"
./supabase/baseline-migration-history.sh
```

It marks every file in `migrations/` as applied, removes history rows that
have no file, then reads the history back and fails unless it matches. Only
the history table changes; schema and data don't. Safe to re-run. Use the
direct connection or the session pooler (port 5432), and percent-encode
special characters in the password (`@` → `%40`, `:` → `%3A`, `/` → `%2F`,
`#` → `%23`); the script refuses a URL with an unencoded `@`.

**Each new migration:**

1. Add `migrations/NNNN_name.sql` with the next number after the highest on
   `main` (`0099` onward; CI's `check-migration-numbers.sh` rejects a reused
   number), and update `schema.sql` to match. CI's **Migrations replay** job
   builds a fresh database from `migrations/` + `seed.sql` (exactly what a
   preview branch does) and runs `tests/*.sql` on it, so a migration that only
   works on top of a hand-fixed database fails the PR.
2. After it merges, from an up-to-date `main`:

   ```bash
   npx supabase db push --dry-run
   npx supabase db push
   ```

   The dry run lists exactly what will run; it should be only the new files.

**Don't** paste migrations into the SQL editor or apply them through other
tools (the Supabase MCP, the dashboard's migration runner): that records a
different version, or none, and `db push` then refuses ("Remote migration
versions not found in local migrations directory"). If that happens, rerun
`baseline-migration-history.sh`, but only once the database really has every
file in `migrations/`.

## What you get

**Tables**: `profiles`, `partners`, `partner_documents`, `settings_entries`, `app_settings`, `rides`.

**Storage buckets**:
- `avatars` (public)
- `app-assets` (public — app icon, splash, banners)
- `partner-documents` (private, owner-only)
- `ride-attachments` (private)

**RLS** is on by default. Defaults:
- Users can read/update their own `profiles` row.
- Partners + settings are readable by authenticated clients.
- Admin/back-office writes should use the `service_role` key.

## Push notifications

Push delivery goes through Expo's push service for Expo tokens and Firebase
Cloud Messaging for the Flutter app's tokens. The schema adds two tables
(`push_tokens`, `push_notifications` — see `migrations_archive/00421_push_notifications.sql`,
already folded into `schema.sql`) and the `send-push` edge function that fans
messages out.

Devices register their push token automatically on sign-in (the Flutter app's
`lib/src/data/push_service.dart`; the retired Expo app's
`contexts/PushNotificationContext.tsx`). The in-app admin screen
*Settings → Push Notification* composes a message, picks an audience
(Everyone / Partners / Users) and dispatches it.

`setup.sh` deploys the sender function automatically when the Supabase CLI is
on `PATH` (skip with `--no-functions`). To deploy it on its own — required, or
the in-app *Push Notification* screen reports "Send failed" because
`supabase.functions.invoke("send-push")` has nothing to call:

```bash
supabase functions deploy send-push --no-verify-jwt
```

The function reads tokens with the `service_role` key, which Supabase injects
as `SUPABASE_SERVICE_ROLE_KEY` for deployed functions — no extra secret needed.
"Partners" vs "Users" is resolved by membership in the `partners` table
(the legacy "drivers" audience key is still accepted as an alias for partners).

## Re-seeding

```bash
./supabase/setup.sh --reset   # nuke + rebuild + seed
```

## Extending

Add new settings categories by inserting rows into `settings_entries` with a
new `category` string — the app's `AdminDataContext` already groups entries
by category.
