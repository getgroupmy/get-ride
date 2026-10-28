# GET.ride super app: planned services

GET.ride will grow from rides into a super app with many on-demand
services. This note records the services planned for the near future (from
the product owner, October 2026), so new work fits them. The screens shown
as reference were a competitor's. Use them for the kinds of service only:
never copy their names, artwork, icons or branding.

## Planned services

| Area | Service | What it is |
|---|---|---|
| Transport | Car (rides) | Today's app: rides, Ride later (scheduled), multi-stop, bidding |
| | Transit | Public transport: Nearby / Metro (MRT, LRT lines) / Bus tabs, stops with live arrival times, route search, saved (favourite) routes, an MRT map and trip planner |
| | Bus & Ferry | Intercity tickets (partner app) |
| | Map | A map of the city |
| Delivery | Food | Restaurants: Delivery, Dine Out (deals), Pickup; cuisines, Near Me, Order Again, cart |
| | Mart | Supermarkets and convenience: categories (Mart, Mall, Health & Beauty, Pet Care, Florists & Gifts, Open 24/7, OTC Medicine), most popular stores, product cards with price and shop rating |
| | Grocery | A partner grocer's own stores: branches with delivery fee and time, in-store prices |
| | Mall | Brand stores: fashion, electronics, pharmacy and the like |
| | Express | Parcel delivery: from / to, saved delivery places, delivery form to share with recipients, claims, delivery guarantee, book again |
| Dining | Dine Out | Nearby deals, book a table, in-your-city collections, top deals of the week, flash deals |
| Money | Wallet | Balance, Top Up, Scan to Pay, Send, Receive (GET.coin and wallet QR exist today) |
| | PayLater | Credit with offers: Pay in 4 or more, categories, top offers, scan any DuitNow QR |
| | Finance | Accounts and credit (e.g. flexible credit), financial services |
| | Loans | Personal loans |
| | Bills & prepaid | Utility bills, mobile prepaid |
| | Credit Report | Partner app |
| Cover | Insurance | Ride Cover (per ride: voucher if the pickup is late, personal accident cover); Explore / My Plans |
| | Travel Cover | Travel insurance per day, by an underwriter |
| | Car Cover | Motor insurance (partner app) |
| Travel | Hotels | Book through partners (Agoda, Booking.com), earn rewards |
| | E-sim | Data for travel (partner app) |
| Other | Gifts | Send gifts (coffee, bubble tea, pastries); occasion cards; redeem received gifts |
| | Games, Dramas | Entertainment partner apps |
| Home | Super-app home | Search, wallet/PayLater card, a grid of every service with "more" in a sheet, quick tiles ("Ride to …", "Schedule a ride"), Order Now carousel, Ordered before |

## How it fits what is built

- **Services tree** (`lib/src/core/service_tree.dart`):
  - Service Settings entries are the master services: Car, Food, Mart, Express and so on.
  - Anything under them (vehicle services, food menus, mart categories, parcel sizes, cover plans …) is a sub-service. It names its parents in `parentServices`, to any depth.
  - A new category joins the tree, and the per-region switches in Admin → Country / States / Cities, without new code.
- **Regions**:
  - Each region switches services on or off, and blocks pickups, drop-offs or both. A delivery's "deliver to" is a drop-off.
  - Fare tariffs, taxes, surcharges and scheduled rules are set per region and service.
- **Home service boxes** (Admin → Display) link to a master service by id. The region's switches show unavailable ones as coming soon.
- **Wallet, GET.coin, QR pay, saved places, favourites, scheduled bookings and chat** already exist. Build on them rather than starting again.
- **Rider live map** ("God View" for riders, migration 0322): the home map's honeycomb button (`Icons.hive`) turns on Busy areas, My people (Family) and Team (Business accounts), and Cars near me shows free cars, anonymous and moved. Admin → Settings → Rider live map sets each mode per region; every mode starts off, and the server decides everything shown (`rider_live_map_*` functions, `lib/src/core/rider_live_map.dart`, `lib/src/features/ride/live_map_overlays.dart`). People show only through Family's disclosed location sharing, and company trips only while they run, to the roles the admin allows.
