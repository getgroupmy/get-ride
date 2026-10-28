# Test database (office NAS)

A copy of the live get.ride database on the office NAS, refreshed every
night, with personal data scrambled, where a pull request's migrations are
tried before the owner runs them live. Admin › Settings › Office NAS › Test
database shows it: when the copy was refreshed, whether it is scrambled, the
last migration tried and its result, and a **Try migration from PR #** box.

- **Nightly refresh** at the time set in Admin (office time, 02:30 by
  default): the newest backup that `deploy/nas-backup` wrote (36 hours old at
  most) is restored; if there is none, the runner takes a `pg_dump` of the
  live database itself with a **read-only** user. The new copy replaces the
  old one only once it is ready.
- **Scrambled**: names, phones, IC / passport numbers, emails, addresses,
  photo paths and more are replaced (list below) before the copy is kept.
  Turning that off is for full admins only.
- **Try migration from PR #**: the NAS fetches the PR's new or changed files
  in `supabase/migrations` from GitHub (read-only), applies them in order to a
  throw-away copy of the copy, runs them a second time (migrations here must
  be re-runnable), and reports pass or fail, the error and how long it took.
  A branch name works too when there is no PR yet.
- It **only calls out**, to get.ride (the `nas-testdb` function) and GitHub:
  no port is opened on the NAS or the router, and no tunnel is needed.
- The database container has **no internet** (an internal Docker network):
  whatever a migration under test tries to send out (pg_net) goes nowhere,
  and the copy's API keys are blanked anyway.
- get.ride doesn't depend on it. With the NAS off, the tab says the runner is
  offline and a PR waits until it is back.

## What the NAS needs

- Synology DSM 7.2 or later with **Container Manager**, on an x86-64 model.
- About **4 GB of memory** for the database while it restores (the compose
  file caps it at 4 GB) and 1 GB for the runner.
- Disk: about three times the live database's size (the copy, the next copy
  while it is made, one download).

## 1. A read-only user on the live database (for pg_dump)

Only needed while there are no backups on the NAS (`deploy/nas-backup`), but
worth having as the fallback. In Supabase › SQL Editor, with a long random
password of letters and digits:

```sql
create role nas_reader login password 'CHANGE-ME-long-random';
grant pg_read_all_data to nas_reader;
```

If Supabase refuses the second line, grant it table by table instead:

```sql
grant usage on schema public, auth, storage to nas_reader;
grant select on all tables in schema public, auth, storage to nas_reader;
grant select on all sequences in schema public to nas_reader;
alter default privileges in schema public grant select on tables to nas_reader;
```

Its connection string is the **Session pooler** one (Supabase › Connect ›
Session pooler; the direct address needs IPv6, which most office lines
don't have), with the user written `nas_reader.<project-ref>`:

```
postgresql://nas_reader.rqlavogkgywxspuxgiwk:PASSWORD@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres
```

## 2. A read-only GitHub token

GitHub › Settings › Developer settings › **Fine-grained tokens** › Generate:
repository access **Only select repositories** › `getgroupmy/get-ride`;
permissions **Contents: Read-only** and **Pull requests: Read-only**
(Metadata: Read-only comes with them). Nothing else. Copy the token.

A PR from someone else's fork is never run.

## 3. Get a connection code

Admin › Settings › Office NAS › **Test database** › **Connect** (full admins
only). Give it a name and **Get code**. The code (`XXXX-XXXX`) works once,
for 10 minutes, and is used when the runner first starts (step 5): if it runs
out, make a new one.

## 4. Put the files on the NAS

1. If **File Station** has no `docker` shared folder yet: **Control Panel** ›
   **Shared Folder** › **Create**, name `docker` on Volume 1, and give your
   account Read/Write.
2. **File Station**: make the folder `docker/nas-testdb` and upload this
   folder's files into it: `Dockerfile`, `docker-compose.yml`, `core.py`,
   `runner.py`, `prepare.sql`, `scramble.sql`, `requirements.txt`,
   `.env.example` (or upload them as a zip and **Extract here**).
3. Over SSH, in that folder, make `.env` and fill it in:

   ```sh
   cd /volume1/docker/nas-testdb
   cp .env.example .env
   vi .env      # PAIR_CODE, LOCAL_DB_PASSWORD, SOURCE_DB_URL, GITHUB_TOKEN
   chmod 600 .env
   ```

   - `PAIR_CODE`: the code from step 3.
   - `LOCAL_DB_PASSWORD`: make one up (letters and digits, 24 or more); it
     never leaves the NAS. `openssl rand -hex 16` makes one.
   - `SOURCE_DB_URL`: the read-only connection string from step 1.
   - `GITHUB_TOKEN`: the token from step 2.
   - `BACKUPS_HOST_DIR`: the folder `deploy/nas-backup` writes database
     backups to (for example `/volume1/backup/getride/db`), once it runs.
     Until then leave `./backups`.

4. Make the folders the containers keep their files in (Synology's Docker
   doesn't make them, and the containers won't start without them):

   ```sh
   mkdir -p data work backups pgdata
   ```

## 5. Build and start it (SSH)

In `/volume1/docker/nas-testdb`:

```sh
sudo docker compose build          # a few minutes on the DS224+
sudo chown "$(sudo docker run --rm getride-nas-testdb:1 id -u)" data work
chmod 700 data
sudo docker compose up -d
sudo docker logs -f nas-testdb
```

The runner runs as its own user, not root, so `data` and `work` are given to
that user. If `docker compose` isn't found, use `docker-compose`.

1. The log shows `Connected as …`, then `Refreshing the copy from …` (the
   first copy is made at once; after that, every night). **Ctrl+C** stops
   watching; it keeps running. Admin shows the runner **Online**.
2. Remove the code from `.env` (it is used once):
   `sed -i 's/^PAIR_CODE=.*/PAIR_CODE=/' .env`

The first copy takes a while: about 5 to 15 minutes for a database of a few
GB on the J4125. Admin shows "Busy: refreshing the copy" meanwhile.

Container Manager (**Project** › **Create**, path `docker/nas-testdb`, **Use
existing docker-compose.yml**) also runs it, once the folders are made as
above.

## Trying a PR's migrations

Admin › Settings › Office NAS › Test database › **Try migration from PR #**:
type the PR number (`554`, `#554` or the PR's link) or a branch name and
**Try**. Within a minute the NAS:

1. asks GitHub for the PR's head commit and its new or changed files in
   `supabase/migrations/` (a removed file is left out), and downloads them at
   that commit;
2. makes `getride_try` from last night's copy (a quick file copy);
3. runs each file in name order with `psql -v ON_ERROR_STOP=1
   --single-transaction`, timing each, and stops at the first error;
4. if all went in, runs them all again: a migration that fails the second
   time passes, with "Second run: failed …" shown under it;
5. drops `getride_try` and reports: passed or failed, the error psql gave
   (the ERROR, LINE and CONTEXT lines), the files, the commit and the time.

The copy itself is never changed by a try. The SQL tests in
`supabase/tests/` are not run here (CI runs them on every PR).

## What is scrambled

`scramble.sql` runs on the new copy before it is kept, with triggers off (so
the guards on approved partners' details don't stop it). The same value
becomes the same scrambled value everywhere in one night (a phone in
`profiles` and in `partners` still match), with a fresh random salt each
night, so nothing can be traced back.

| Kind | Columns | Becomes |
|---|---|---|
| Names | `name` in profiles, partners, emergency contacts, fleet owners, stand people; every `rider_name`, `partner_name`, `driver_name`, `recipient_name`, `booked_for_name`, `owner_name`, `holder_name`, `caller_name`, `sender_name`, `read_name` …; `first_name`, `last_name`, `full_name`, `display_name` | `Test 3fa9c1` |
| Phones | `phone`, every `*_phone`, `mobile`, `msisdn` | `+601` and 10 digits |
| ID numbers | `ic`, `owner_ic`, `read_ic`, `nric`, `passport`, `id_number`, `ic_number`, bank `account_no` … | `TEST` and 12 letters |
| Emails | `email`, every `*_email`, `emails` | `user-…@example.invalid` |
| Addresses | `address`, every `*_address`, `full_address` | `Test address …` |
| Places | `pickup_name`, `drop_name`, `pickup_place` … | `Place …` |
| Photo paths | `photo`, `avatar`, `selfie`, `picture` (and their `_url` / `_path`), `profile_image`, `id_image`, `image_front`, documents' `file_url` / `file_url_back`, cargo and pickup proof paths | `scrambled/….jpg` |
| Plates | `plate`, every `*_plate` | `TST1234` |
| IP addresses | `ip`, `ip_address` | `192.0.2.x` (a documentation range) |
| Birth dates | `birth_date`, `date_of_birth`, `dob` | 1 January of the same year |
| Chat | `body`, `message`, `content`, `text` in `*message*` / `*chat*` tables | `[scrambled]` |
| What was read off documents | `raw_user_meta_data`, `identity_data`, `ai_verification`, `doc_read_jobs.result` | `{}` |
| Sign-in | auth sessions, refresh and one-time tokens, MFA challenges, flow state, the auth audit log | emptied; every `*_token` in `auth` blanked |
| Secrets | any JSON field named like key / secret / token / password (API keys, payment gateway secrets), every key in Admin › API Keys, text columns named `*secret*` / `*api_key` | blanked |

Kept as they are: ids, times, amounts, statuses, settings and catalogue
names, and map coordinates (needed for routes and fares).

To add a column: put its name in the right pattern in `pg_temp.scramble_kind`
in `scramble.sql`, add it to this table, and run the tests below.

Turning scrambling off (Admin, full admins only) keeps real data in the next
copy: for a short check only, and switch it back on after.

## Looking at the copy yourself

From an SSH session on the NAS:

```sh
sudo docker exec -it nas-testdb-db psql -U supabase_admin -d getride_test
```

(or uncomment `ports` in `docker-compose.yml` to reach it from a PC in the
office; never forward that port on the router).

## Updating

Upload the new files over the old ones and, in Container Manager, **Project**
› `nas-testdb` › **Action** › **Build**. The key in `data/` and the copy in
`pgdata/` are kept.

## If something is wrong

| The log says | Do this |
|---|---|
| `Bind mount failed: '…/nas-testdb/data' does not exist` | Make the folders as in step 4, then `sudo docker compose up -d`. |
| `Can't save to /data …` | `data` isn't the runner's: run the `chown` and `chmod` lines of step 5, then restart. |
| `Not connected. Make a code …` | Put a fresh `PAIR_CODE` in `.env` and restart the project. |
| `Pairing refused … wrong or has expired` | The code is single-use and lasts 10 minutes: make a new one. |
| `This runner was disconnected in Admin` | It was removed in Admin: make a new code and put it in `.env`. |
| `No fresh backup … and no SOURCE_DB_URL` | Set `SOURCE_DB_URL` (step 1) or `BACKUPS_HOST_DIR`. |
| `pg_dump failed: … server version` | The live database is newer than the runner's tools: set `PG_MAJOR` in the `Dockerfile` to its major version and rebuild; set `PG_IMAGE` to a Supabase image of that version. |
| `GitHub said 404 …` | The token can't see the repository, or the PR number is wrong. |
| `Scrambling failed, copy not kept` | The error says which column; the old copy stays. Tell the developer (scramble.sql). |
| `get.ride or GitHub can't be reached` | Check the NAS's internet connection; it retries every minute. |

Admin shows the runner **Offline** when it hasn't checked in for 3 minutes.
A run left "running" for 45 minutes (the NAS went off) is marked failed.

## Tests

- `pytest deploy/nas-testdb/test_core.py`: when the refresh is due, which
  backup is picked, which PR files are migrations, the error shown in Admin
  and that passwords never reach it.
- `TEST_PG_URL=postgresql://… pytest deploy/nas-testdb/test_scramble.py`:
  `scramble.sql` on a small made-up schema in a real (throw-away) Postgres:
  every kind above, the same value scrambled the same way, settings kept,
  secrets blanked, triggers back on after.
- `supabase/tests/nas_testdb_stats_0321.sql` and
  `supabase/functions/_shared/nas_testdb_test.ts`: the server side.
