# KIV (keep in view)

Items the owner has parked. Remove an item in the same PR that ships it.

## Services, partner types and vehicle services (study of 26 Oct 2026)

Low:

(M3, the list's quick Approve, and L3, the step count, are in the partner review fixes.)

## Owner setup

- Online payment: wallet top-up through the payment gateway is built (Fiuu, Billplz; FPX and e-wallets). Add the merchant account keys in Admin › Payment gateways, then turn Card back on. DuitNow QR top-up is not built.
- AI Reports email: add the Resend key in Admin › Settings › API Keys (Email › Resend) and verify the getride.my domain in Resend. Until then scheduled report emails don't send; downloads work.
- Sign-in checks face match, AWS Rekognition (later): add the key in Admin › Settings › API Keys (Amazon Web Services › Rekognition) as `ACCESS_KEY_ID:SECRET_ACCESS_KEY` (or add `:region`), an IAM user allowed `rekognition:CompareFaces` and `rekognition:ListCollections` only. Until then Admin › Documents › Sign-in checks shows "Not checked · No AWS key yet". AWS is the default in Admin › Dispatch › Accounts › Face match.
- Sign-in checks face match, self-hosted server (later): run `deploy/face-server` on the Synology NAS behind a Cloudflare Tunnel (face.getride.my), then add it in API Keys (Face match server) and pick Self-hosted server or Self-hosted, then AWS. Steps in [deploy/face-server/README.md](../deploy/face-server/README.md).
- Office NAS backups and uptime: deploy the `nas-ops` and `uptime-check` functions (`--no-verify-jwt`) and apply migration 0318, then run `deploy/nas-backup` on the NAS (connection code from Admin › Settings › Office NAS, the database connection string and the storage service key in its `.env`, the encryption key printed once at setup: keep it), set up Hyper Backup to Backblaze B2 or Synology C2, and turn on the alert channels (a Telegram bot token in API Keys › Telegram › Bot, the Resend key for email). Steps in [deploy/nas-backup/README.md](../deploy/nas-backup/README.md).
- Sign-in checks ID reading, Google Cloud Vision (optional): enable Cloud Vision API in a Google Cloud project with billing, make an API key kept to that API, add it in API Keys (Google › Cloud Vision (ID reading)) and test it, then switch Google Vision on in Admin › Dispatch › Accounts › ID card reading (the order: Phone, then NAS, then Google Vision). First 1,000 reads a month are free. Deploy the `id-read` function and apply migration 0283 first.
- Sign-in checks on the office NAS (migration 0320): apply 0320, deploy the `id-read`, `face-compare` and `doc-reader` functions, then update the doc-reader on the NAS to version 1.1 (`deploy/doc-reader/README.md`, Updating) so it reads MyKad and passports. The orders (ID reading: Phone, then NAS, then Google Vision; face match: NAS, then AWS, then in-browser) and the "Needs a closer look" percentage are in Admin › Settings › Office NAS › ID and face and in Dispatch › Accounts. The in-browser check loads its face models from cdn.jsdelivr.net (about 9 MB, once per browser): allow it if the site's content policy is made strict.
- Test database on the NAS (later): run `deploy/nas-testdb` (a read-only database user, a read-only GitHub token, a code from Admin › Settings › Office NAS › Test database), deploy the `nas-testdb` function (`--no-verify-jwt`) and apply migration 0321. Steps in [deploy/nas-testdb/README.md](../deploy/nas-testdb/README.md).
- Visitor stats on the NAS (later): run `deploy/nas-stats` (Umami) behind a Cloudflare Tunnel at stats.getride.my, add the Umami key in API Keys and the website ID in Admin › Settings › Office NAS › Visitor stats, deploy the `nas-stats` function, then set the STATS_SCRIPT_URL and STATS_WEBSITE_ID repository variables. Steps in [deploy/nas-stats/README.md](../deploy/nas-stats/README.md).

## Not built here (start a new session)

- A God View page in the rider app. Not built; God View stays in the admin.
