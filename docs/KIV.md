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

## Services, partner types and vehicle services (study of 26 Oct 2026)

High:
- H1 Approved drivers can't go online with the car they registered: owner's ID is required but not saved when the driver is the owner (`firstVehicleStep`, `_saveVehicle`); an approved vehicle should count as complete; one-off fix for stuck vehicles.
- H2 The partner type's allowed services are only checked on the open-request list: `driver_takes_service` (pushes, offers, scheduled rides) should check the partner type too.
- H3 A new partner type takes every service, and a partner with no vehicle can offer on a vehicle service. Decide: no row means none, or a required picker on the type form; the server refuses offers on vehicle services without a vehicle.
- H4 A service's per-minute rate and minimum fare are never used when there's no fare tariff. Decide: price with them, or remove the fields.

Medium:
- M1 Register vehicle has no Vehicle service picker, and the review has no Vehicle service line.
- M2 Services, types, switches, locks and promotions are linked by name: renaming breaks them. Link by id.
- M4 Region service switches: Inherit / On / Off, and a server check that the service is offered at the pickup.
- M5 Approved vehicle permit never switches its service back on (trigger compares the permit key with the permit id).
- M6 Citizens only, business registration, driver/vehicle permit and age-limit covers are app-only: move into SQL rules.
- M7 An approved partner can change their partner types without re-review.
- M8 Two accounts can register the same MyKad number. Decide: flag in the review, or also a unique index.
- M9 Vehicles added later skip the per-service checks.

Low:
- L1 One default for "partners must register a vehicle".
- L2 Built-in fallback service names match no seeded rules.
- L4 A partner with no vehicle sees "No vehicle chosen" instead of "No vehicle needed".
- L5 Repeat vehicle wizard after registration (goes with H1).
- L6 Vehicle permits opens on the first country, not the admin's.
- L7 Driver service locks: long names break the row layout.
- L8 City to City booking flow; per-service commission rate.

(M3, the list's quick Approve, and L3, the step count, are in the partner review fixes.)

## Owner setup

- AI Reports email: add the Resend key in Admin › Settings › API Keys (Email › Resend) and verify the getride.my domain in Resend. Until then scheduled report emails don't send; downloads work.
- Sign-in checks face match, AWS Rekognition (later): add the key in Admin › Settings › API Keys (Amazon Web Services › Rekognition) as `ACCESS_KEY_ID:SECRET_ACCESS_KEY` (or add `:region`), an IAM user allowed `rekognition:CompareFaces` and `rekognition:ListCollections` only. Until then Admin › Documents › Sign-in checks shows "Not checked · No AWS key yet". AWS is the default in Admin › Dispatch › Accounts › Face match.
- Sign-in checks face match, self-hosted server (later): run `deploy/face-server` on the Synology NAS behind a Cloudflare Tunnel (face.getride.my), then add it in API Keys (Face match server) and pick Self-hosted server or Self-hosted, then AWS. Steps in [deploy/face-server/README.md](../deploy/face-server/README.md).
- Sign-in checks ID reading, Google Cloud Vision (optional): enable Cloud Vision API in a Google Cloud project with billing, make an API key kept to that API, add it in API Keys (Google › Cloud Vision (ID reading)) and test it, then pick Phone, then Google Vision (or Google Vision always) in Admin › Dispatch › Accounts › ID card reading. First 1,000 reads a month are free. Deploy the `id-read` function and apply migration 0283 first.

## Synology DS224+ (see docs/NAS.md)

- Face match on the NAS: built (`deploy/face-server`, OpenCV SFace, runs on the J4125); setting it up is under Owner setup. Still parked: the in-browser check (human) as a last fallback, and flagging low matches "Needs a closer look".
- Nightly backups of the database and storage buckets to the NAS.
- Own maps routing and address search for Malaysia (OSRM or Valhalla, Photon or Nominatim) as a provider before Google.
- Uptime monitor (Uptime Kuma) with alerts.
- ID card reading on the NAS (PaddleOCR) instead of Google Vision.

## Not built here (start a new session)

- Family module (rider side menu: family members, children, up to 6 with an admin increase request, location sharing set per family). Not built in this session. To try again, start a new session with the sample (https://claude.ai/artifact/DjAj1VtyL6eJrZsNbTsiAo) and the three disclosed options only: a visible Family viewer the members can see, a logged admin view in God View, and admin-set location visibility. No hidden or covert viewing.
- A God View page in the rider app. Not built; God View stays in the admin.
