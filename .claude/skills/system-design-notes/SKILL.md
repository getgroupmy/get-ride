---
name: system-design-notes
description: Reference notes on large-scale system design (scaling, estimation, rate limiting, consistent hashing, key-value stores, ID generation, notification/chat/news-feed systems, proximity and nearby-friends services, Google Maps, message queues, metrics, payments, digital wallets and more). Use when designing or reviewing backend architecture, capacity estimates, realtime/location features, payment or wallet flows, or when the user asks a system-design question.
---

# System design notes

Condensed notes from [liquidslr/system-design-notes](https://github.com/liquidslr/system-design-notes) (based on *System Design Interview* vols. 1–2). Diagrams from the source repo are not vendored; the text is.

## How to use

1. Start with `references/03-system-design-framework.md` for the 4-step approach (scope → high-level design → deep dive → wrap-up) and `references/02-back-of-the-envelope-estimation.md` for capacity maths.
2. Open only the topic file(s) relevant to the question — don't load them all.
3. Apply the patterns to the actual codebase and constraints in front of you; cite the trade-offs, not just the pattern name.

## Topics most relevant to GET.ride

| Need | Read |
| --- | --- |
| Matching riders to nearby drivers, geo queries | `16-proximity-service.md`, `17-nearby-friends.md` |
| Routing, ETAs, map tiles | `18-google-maps.md` |
| Push / SMS / in-app notifications | `10-notification-system.md` |
| Support chat, realtime messaging | `12-chat-system.md` |
| Wallet, top-ups, commissions, payouts | `26-payment-system.md`, `27-digital-wallet.md` |
| Throttling OTP / PIN attempts, API abuse | `04-rate-limiter.md` |
| Event pipelines, ride analytics | `19-distributed-message-queue.md`, `20-metrics-monitoring-and-alerting-system.md` |

## All references

`references/01-scaling.md` · `02-back-of-the-envelope-estimation.md` · `03-system-design-framework.md` · `04-rate-limiter.md` · `05-consistent-hashing.md` · `06-key-value-store.md` · `07-unique-id-generator.md` · `08-url-shortener.md` · `09-web-crawler.md` · `10-notification-system.md` · `11-news-feed-system.md` · `12-chat-system.md` · `13-search-autocomplete.md` · `14-youtube.md` · `15-google-drive.md` · `16-proximity-service.md` · `17-nearby-friends.md` · `18-google-maps.md` · `19-distributed-message-queue.md` · `20-metrics-monitoring-and-alerting-system.md` · `21-ad-click-event-aggregation.md` · `22-hotel-reservation-system.md` · `23-distributed-email-service.md` · `24-s3-like-object-storage.md` · `25-real-time-gaming-leaderboard.md` · `26-payment-system.md` · `27-digital-wallet.md` · `28-stock-exchange.md`
