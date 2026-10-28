# Synology DS224+: what it can host for get.ride

Notes from 24 Oct 2026. Each item is a separate PR when the owner says go;
the ones built say where. The KIV list (`docs/KIV.md`) points here.

## The box (checked 24 Oct 2026)

| | Measured | Needed for the plans below |
|---|---|---|
| Memory | 18 GB (about 12 GB available) | about 2 GB for face match, 4–6 GB for maps |
| CPU | Intel Celeron J4125, 4 cores | any x86-64; a face comparison takes about 1–2 s |
| Docker (Container Manager) | 24.0.2 | 20 or newer |
| Disk (volume1) | 7.0 TB, 4.6 TB free | about 3 GB face match, about 20 GB maps |

Checked with: `free -m; nproc; cat /proc/cpuinfo | grep "model name" | head -1; sudo docker version --format '{{.Server.Version}}'; df -h /volume1 | tail -1`

## The one rule

get.ride must keep working when the NAS is off. Everything on it is a
**fallback** (face match, maps) or a **side job** (backups, monitoring). Never
the main database, payments, or the app itself: home internet and a single box
are not reliable enough for what riders and drivers use every minute.

Reached from the internet through **Cloudflare Tunnel** (free, getride.my is
already on Cloudflare): no port opened on the router. Every service on it asks
for a secret key that only get.ride's server functions hold (Admin → API Keys).

## Face match (selfie against the ID photo)

Used by Documents → Sign-in checks (migration 0281, `face-compare` function).
The score only helps the admin decide: never an automatic approve or reject.

| Option | Cost | Runs when | Notes |
|---|---|---|---|
| **Self-hosted on the NAS** (built: `deploy/face-server/`) | free | 24/7, on upload | OpenCV only: YuNet finds the face, **SFace** (Apache 2.0) compares. No TensorFlow, so it runs on the J4125 (no AVX). About 200 MB memory. Photos are compared and forgotten, never stored. Setup: `deploy/face-server/README.md`. |
| **AWS Rekognition** CompareFaces | about USD 1 / 1,000; first-year free tier | 24/7, on upload | Key in API Keys → Amazon Web Services → Rekognition, saved as `ACCESS_KEY_ID:SECRET_ACCESS_KEY[:region]` (default ap-southeast-1). IAM user with only `rekognition:CompareFaces` and `rekognition:ListCollections`. Already built. |
| **human** in the admin's browser ([vladmandic/human](https://github.com/vladmandic/human), MIT) | free | only while an admin has the queue open (scores everything waiting, saves it) | About 10 MB of model files downloaded once per browser. Photos never leave the admin page. Cannot run in the native phone apps. |

Admin › Dispatch › Accounts › Face match picks the source: AWS (default),
self-hosted, or self-hosted then AWS. The in-browser check is still parked. Below a set match (for example 60%) the check is marked "Needs a
closer look" and sorted to the top.

### Licences: what not to use

- **DeepFace's default model, VGG-Face**: non-commercial only. Not for get.ride.
- **ArcFace / InsightFace** models (also inside DeepFace): trained on data with
  research-only terms. Avoid.
- DeepFace's own code is MIT; the licence that matters is the model's. Check
  the model's page before switching.

### Not a face-match option

- **Google Cloud Vision**: it finds faces (position, angle, expression) but does
  not compare two faces, and Google does not sell face matching. It is good at
  **reading text**: a possible server-side fallback for reading MyKad and
  passports when the phone's ML Kit can't (and on web/desktop). First 1,000
  reads a month free, then about USD 1.50 / 1,000. Uses the Google Cloud project
  that already has Maps; enable the Vision API there.
- Open-source alternative for reading ID cards on the NAS: **PaddleOCR** (Apache 2.0).

## Other things worth hosting, best first

1. **Nightly backups** (built: `deploy/nas-backup`, migration 0318): the
   database (pg_dump) and the storage buckets (permits, IDs, media) copied
   every night and encrypted with a key only the owner holds, 30 nightly and
   12 monthly kept (both set in Admin), a monthly restore test into a test
   database on the NAS, plus an off-site copy with Hyper Backup (Backblaze B2
   or Synology C2). Guards against a bad migration, a mistaken delete, or a
   provider problem. Admin › Settings › Office NAS › Backups.
2. **Own maps** for Malaysia, Singapore and Brunei (OpenStreetMap). *Built:*
   `deploy/nas-maps/` (migration 0319). **OSRM** for routes and travel
   times, **Photon** for search and address lookup, and **Protomaps** vector
   tiles for the web map. It is one more provider in Admin → Maps, "Office
   NAS (OpenStreetMap)", meant to go before Google. Admin → Settings →
   Office NAS → Maps shows its status and the weekly refresh, and what it
   answered and saved. It also holds a Default rule and region rules: each
   part on or off, and how long to wait for the NAS before the next
   provider (1.5 s by default). Routes and search are reached through a
   Cloudflare Tunnel with a secret header only the geo function holds. The
   tiles are public and cached by Cloudflare. About 5 GB memory; data
   refreshed weekly by `refresh.sh` from Task Scheduler. Setup:
   `deploy/nas-maps/README.md`.
3. **Uptime monitor** (built: `deploy/nas-backup` with the backups, and the
   `uptime-check` function on a pg_cron schedule so a dead NAS is still
   reported; our own instead of Uptime Kuma, so the targets, history and
   alerts live in Admin): checks getride.my, the admin, the server functions,
   the database, the SMS gateway phones and the payment gateway; alerts after
   N failed checks with a "resolved" message, on admin app push, Telegram,
   WhatsApp/SMS or email. Admin › Settings › Office NAS › Uptime.
4. **Face match** (above) and **ID reading** (PaddleOCR).
5. **A test copy of the database** to try migrations on before the owner runs
   them live. About 4 GB memory.
6. **Website visitor stats** (**Umami** or **Plausible**): privacy-friendly, no
   cookie banner.
7. **Automations** (**n8n**): for example a daily summary on WhatsApp, an alert
   when SOS fires.

## Not a good fit

- The main database, payments, or the app: not reliable enough at home.
- **Call relay (TURN / coturn)**: needs UDP ports open to the internet;
  Cloudflare Tunnel can't carry it.
- **AI models for AI Reports**: the J4125 has no graphics chip; far too slow.
  Keep the cloud AI providers.
