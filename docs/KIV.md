# KIV (keep in view)

Items the owner has parked. Remove an item in the same PR that ships it.

## City ride, before launch

- Online payment: DuitNow QR, FPX and e-wallets through Fiuu or Billplz into GET.wallet. Waits for the merchant account; turn Card back on once the keys are set.
- Driver selfie check before going online, plus random checks (through `document-ai-verify`).
- Report a trip from the receipt (opens a support ticket with the ride attached), and let the rider block a driver.
- Driver request filters: minimum fare, maximum pickup distance, sort by price or distance.
- Passenger insurance and APAD permit info on the receipt and the Safety page.

## City ride, after launch

- Tips after the trip (GET.wallet).
- Waiting-time charge on city rides.
- Luggage option on city rides.
- Rider-side audio recording.
- Premium tier.

## Freight and Courier, after launch

- Parcel cover.
- Round trip.
- Floor (stairs) and cold-truck add-ons.
- Cash on delivery for items.
- Business accounts.

## Owner setup

- AI Reports email: add the Resend key in Admin › Settings › API Keys (Email › Resend) and verify the getride.my domain in Resend. Until then scheduled report emails don't send; downloads work.

## Synology DS224+ (see docs/NAS.md)

- Face match on the NAS: DeepFace (SFace / Dlib models) in Docker behind Cloudflare Tunnel; `face-compare` tries the NAS, then AWS, then the in-browser check (human); low matches flagged "Needs a closer look".
- Nightly backups of the database and storage buckets to the NAS.
- Own maps routing and address search for Malaysia (OSRM or Valhalla, Photon or Nominatim) as a provider before Google.
- Uptime monitor (Uptime Kuma) with alerts.
- ID card reading fallback: Google Cloud Vision or PaddleOCR on the NAS.
