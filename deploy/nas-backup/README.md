# Backups and uptime (office NAS)

Two side jobs for GET.ride on the office NAS, in one app. Admin → Settings →
Office NAS shows them (Overview, Backups, Uptime).

**Nightly backups**

- Every night at the time set in Admin (02:00 Malaysia time unless changed),
  the database is dumped with `pg_dump` (your tables, sign-ins and the storage
  index: `public`, `auth`, `storage`), and the storage buckets' files that are
  new or changed since the night before are copied. Every bucket is copied
  unless it is switched off in Admin → Backups (it lists the buckets the NAS
  found: today `avatars`, `ID_Image`, `provider-documents`,
  `vehicle-documents`, `support-media`, `ride-chat-media`, the voice
  protection, pets and cargo photos, `partner-statements`, `airport-guides`,
  `app-branding`, `ai-reports` and the rest).
- Everything is **encrypted on the NAS** with [age](https://age-encryption.org)
  before it is written: the NAS keeps only the public half of the key, which
  can lock but not open. The secret half is printed **once**, at setup, for
  you to keep (step 4). Someone who takes the NAS or its disks can't read the
  backups.
- It keeps 30 nightly copies of the database and the first backup of each of
  the last 12 months (both changeable in Admin). Storage files are a copy that
  only grows: a file deleted on GET.ride stays on the NAS, so a mistaken delete
  can be undone.
- Once a month (the 1st unless changed) it **restores that night's dump into a
  test database** on the NAS (the `nas-restore-db` container, never the live
  database) and checks every table came back and the main tables have the rows
  the live database had. Pass or fail shows in Admin and a failure alerts you.
- **Back up now** and **Run a restore test** in Admin start one within a
  minute.
- Off-site: Synology's own **Hyper Backup** copies the backup folder to
  Backblaze B2 or Synology C2 (step 5).

**Uptime monitor**

- Checks getride.my, the admin, the server functions, the database and the
  payment gateway every minute from the office, and reports to GET.ride. The
  same checks run every 5 minutes from the cloud too (with the SMS gateway
  phones, the NAS itself and last night's backup), so a dead NAS or a dead
  office line is still reported.
- After 2 failed checks in a row (changeable) you get an alert; when it is back,
  a "resolved" message. Each channel is switched on or off in Admin → Uptime:
  admin app push to the full admins, Telegram, WhatsApp/SMS through the SMS
  gateway, email through Resend.

It **only calls out** (the `nas-ops` function): no port is opened on the NAS
or the router, no tunnel. It pairs once with a code from Admin and keeps its
own key in `data/` (only a hash of it is on the server). The database's
connection string and the storage key are in `.env` on the NAS and are never
sent to GET.ride.

GET.ride keeps working when the NAS is off: the backups just wait for it, and
the cloud reports the NAS down.

## What the NAS needs

- Synology DSM 7.2 or later with **Container Manager**, on an x86-64 model.
- Disk: about 3 times the database dump for the nightly copies (a 2 GB dump
  with 30 nightly and 12 monthly copies is about 85 GB) plus the storage
  files once.
- Memory: up to 1 GB for the app and 2 GB for the test database while a
  restore test runs (the compose file caps both).

## 1. Get a connection code

Admin → Settings → Office NAS → Overview → **Connect the NAS** (full admins
only). Give it a name (e.g. `DS224+ office`) and **Get code**. The code
(`XXXX-XXXX`) works once, for 10 minutes, and is used when the app first
starts (step 3): if it runs out, make a new one.

## 2. Put the files on the NAS

1. **Control Panel** → **Shared Folder** → **Create**: `getride-backups` on
   Volume 1 (the backups go here), and `docker` if there isn't one. Give your
   account Read/Write on both. Leave the recycle bin off for `getride-backups`.
2. **File Station**: make the folder `docker/nas-backup` and upload this
   folder's files into it: `Dockerfile`, `docker-compose.yml`, `core.py`,
   `agent.py`, `requirements.txt`, `.env.example`.
3. Over SSH, in that folder, make `.env` and fill it in:

   ```sh
   cd /volume1/docker/nas-backup
   cp .env.example .env
   chmod 600 .env
   vi .env      # or edit it in File Station's Text Editor
   ```

   - `PAIR_CODE`: the code from step 1.
   - `DATABASE_URL`: Supabase dashboard → **Connect** → **Session pooler**,
     the `postgresql://…` line with your database password in it.
   - `SUPABASE_SERVICE_KEY`: Supabase dashboard → **Project Settings** →
     **API Keys** → `service_role` (leave empty to back up the database only).
   - `RESTORE_IMAGE`: Supabase dashboard → **Project Settings** →
     **Infrastructure** shows the Postgres version (e.g. `17.4.1.054`); write
     `supabase/postgres:17.4.1.054`.
   - `RESTORE_DB_PASSWORD`: any long random password (for the test database only).

`GETRIDE_URL` is already your backend's. The `data` folder the app keeps its key
in is made in step 3: Synology's Docker doesn't make it, and the container
won't start without it.

## 3. Build and start it (SSH)

In `/volume1/docker/nas-backup`:

```sh
sudo docker compose build          # about 5 minutes on the DS224+
mkdir -p data                      # where the app keeps its key
sudo chown "$(sudo docker run --rm getride-nas-backup:1 id -u)" data /volume1/getride-backups
chmod 700 data
sudo docker compose up -d
sudo docker logs -f nas-backup
```

The app runs as its own user, not root, so `data` and the backup folder are
given to that user. If `docker compose` isn't found, use `docker-compose`.

1. The log shows `Connected as …` (**Ctrl+C** stops watching; the app keeps
   running). Admin → Settings → Office NAS now shows it **Online**.
2. Remove the code from `.env` (it is used once):
   `sed -i 's/^PAIR_CODE=.*/PAIR_CODE=/' .env`

If the build took longer than the code's 10 minutes, make a new one, put it in
`.env` and run `sudo docker compose up -d --force-recreate nas-backup`.

## 4. Make the encryption key (once)

```sh
sudo docker compose run --rm nas-backup python agent.py setup-key
```

It prints a line starting `AGE-SECRET-KEY-1…`. **That is the only copy.**
Put it in your password manager now, and print it for a safe. It is not kept
on the NAS; without it nobody (you included) can open the backups. The NAS
keeps only the public half (`data/recipient.txt`).

The first backup starts within a minute, then every night. Admin → Backups
shows it.

To change the key later: `… setup-key --replace`. Backups already made still
need the old secret: keep it until they are gone.

## 5. The off-site copy (Hyper Backup)

A copy that isn't in the office covers a fire, a theft or a dead NAS.

1. **Package Center** → install **Hyper Backup**.
2. Make the bucket:
   - **Backblaze B2**: sign up, **Buckets** → **Create a Bucket** (private,
     encryption off: the files are already encrypted), then **Application
     Keys** → **Add a New Application Key** for that bucket only. Note the
     keyID and applicationKey.
   - **Synology C2 Storage**: sign in with your Synology account and pick a
     plan; Hyper Backup connects to it directly.
3. **Hyper Backup** → **+** → **Data backup task** → **S3 Storage** (for B2:
   server **Custom server URL** with the bucket's endpoint, e.g.
   `s3.us-west-004.backblazeb2.com`, and the keyID and applicationKey) or
   **Synology C2 Storage**.
4. Pick the `getride-backups` shared folder. Name the task (e.g.
   `getride-b2`). Schedule it daily at **04:00** (after the backup), turn on
   **Backup rotation** (e.g. keep 30 versions), and leave its own encryption
   off or on as you like (the files are already encrypted).
5. Admin → Backups → **Off-site copy**: pick B2 or C2.

So Admin shows when the off-site copy last ran (else set the date by hand
there):

1. In `docker-compose.yml` take the `#` off the line
   `- /var/log/synolog:/hyperbackup:ro`.
2. In `.env`: `HYPERBACKUP_LOG=/hyperbackup/synobackup.log` and
   `HYPERBACKUP_TASK=getride-b2` (the task's name).
3. `sudo docker compose up -d`.

Reading the log is best effort (DSM's wording changes between versions): if
Admin shows nothing after a night, set the date by hand.

## 6. Alerts

Admin → Settings → Office NAS → Uptime → **Alerts go to**: switch each on and
say where it sends. **Send a test alert** tries them all.

- **Admin app push**: every full admin with the admin app.
- **Telegram**:
  1. In Telegram, open **@BotFather** → `/newbot` → a name (`get.ride
     monitor`) and a username ending in `bot`. It answers with a token
     (`123456:ABC…`).
  2. Admin → Settings → API Keys → **Telegram** → **Bot** → add the token.
  3. Start a chat with your bot (or add it to a group) and send it a message.
     Open `https://api.telegram.org/bot<token>/getUpdates` in a browser: the
     `"chat":{"id":…}` number is the chat id (a group's starts with `-100`).
  4. Put the chat id in Admin → Uptime → Telegram chats.
- **WhatsApp / SMS**: the numbers in Admin → Uptime. They go through the SMS
  gateway's **Ops alert** channel (Admin → Settings → SMS / WhatsApp says
  whether that is SMS or WhatsApp).
- **Email**: a Resend key in Admin → Settings → API Keys → Email → Resend, and
  the addresses in Admin → Uptime. The sender is Admin → Reports' unless one
  is set in Uptime.

## Restoring (you, with the key)

On any computer with [age](https://age-encryption.org) and PostgreSQL 17's
tools:

```sh
echo 'AGE-SECRET-KEY-1…' > key.txt && chmod 600 key.txt
age -d -i key.txt -o db.dump nightly/2026-10-28/db.dump.age
# into a NEW Supabase project (never over the live one by mistake):
pg_restore --clean --if-exists --no-owner --dbname "postgresql://postgres:…@…/postgres" db.dump
# a stored file:
age -d -i key.txt -o ic.jpg storage/ID_Image/<path>/ic.jpg.age
rm key.txt
```

Each night's folder has `manifest.json`: the dump's size, its SHA-256 and the
row counts of the main tables when it was made.

## Updating

Upload the new files over the old ones and, in Container Manager, **Project**
→ `nas-backup` → **Action** → **Build**. The key in `data/` is kept, so it
stays connected.

## If something is wrong

| The log or Admin says | Do this |
|---|---|
| `Bind mount failed: '…/nas-backup/data' does not exist` | Make `data` as in step 3, then `sudo docker compose up -d`. |
| `Set RESTORE_IMAGE in .env` (when starting) | Fill in `RESTORE_IMAGE` and `RESTORE_DB_PASSWORD` (step 2). |
| `Can't save to /data …` | `data` isn't the app's: run the `chown` and `chmod` lines of step 3, then restart. |
| `Not connected. Make a code …` | Put a fresh `PAIR_CODE` in `.env` and restart. |
| `Pairing refused … wrong or has expired` | The code is single-use and lasts 10 minutes: make a new one. |
| `This NAS app was disconnected in Admin` | It was removed in Admin: make a new code and put it in `.env`. |
| `No encryption key on the NAS` | Run step 4. |
| `pg_dump failed: … password authentication failed` | Check `DATABASE_URL` (the database password, not your Supabase login). |
| `pg_dump failed: … server version mismatch` | Supabase moved to a newer Postgres: change `postgresql-client-17` in the Dockerfile to that version and rebuild. |
| Restore test: `The test database isn't running` | `sudo docker compose up -d restore-db`; check `RESTORE_IMAGE`. |
| `GET.ride can't be reached` | Check the NAS's internet connection; it retries every minute. |

Admin shows it **Offline** when it hasn't checked in for 3 minutes, and the
cloud monitor reports the NAS down after 10.

## Tests

`pytest deploy/nas-backup/test_core.py` checks when backups and restore tests
are due, which nightly and monthly copies are kept, which files are copied,
how a restore test is judged, what an uptime check means, the box's numbers
and reading Hyper Backup's log, without the network or a database.
