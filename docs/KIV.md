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
- Sign-in checks ID reading, Google Cloud Vision (optional): enable Cloud Vision API in a Google Cloud project with billing, make an API key kept to that API, add it in API Keys (Google › Cloud Vision (ID reading)) and test it, then pick Phone, then Google Vision (or Google Vision always) in Admin › Dispatch › Accounts › ID card reading. First 1,000 reads a month are free. Deploy the `id-read` function and apply migration 0283 first.

## Synology DS224+ (see docs/NAS.md)

- Face match on the NAS: built (`deploy/face-server`, OpenCV SFace, runs on the J4125); setting it up is under Owner setup. Still parked: the in-browser check (human) as a last fallback.
- Nightly backups of the database and storage buckets to the NAS.
- Own maps routing and address search for Malaysia (OSRM or Valhalla, Photon or Nominatim) as a provider before Google.
- Uptime monitor (Uptime Kuma) with alerts.
- ID card reading on the NAS (PaddleOCR) instead of Google Vision.

## Not built here (start a new session)

- Family module (rider side menu: family members, children, up to 6 with an admin increase request, location sharing set per family). Not built in this session. To try again, start a new session with the sample (https://claude.ai/artifact/DjAj1VtyL6eJrZsNbTsiAo) and the three disclosed options only: a visible Family viewer the members can see, a logged admin view in God View, and admin-set location visibility. No hidden or covert viewing.
- A God View page in the rider app. Not built; God View stays in the admin.
