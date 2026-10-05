/// Partner queue preferences (Expo `partner-ehailing.tsx` "Auto-accept" and
/// "Allow OfferMe requests" toggles).
///
/// * **Auto-accept** takes each request that arrives while it is on, without
///   the partner tapping Accept. Requests already in the queue when it was
///   switched on are left alone (Expo only auto-accepts incoming ones), each
///   request is tried once, and nothing is taken while a claim is in flight.
/// * **Allow OfferMe** off treats bidding requests as fixed-fare: the partner
///   can still accept the rider's price but not counter-offer.
library;

/// The parts of an open request the rules look at.
typedef QueueItem = ({String id, bool offerMe, double? awayKm});

/// The request auto-accept should take now, or null. [seen] holds every id
/// that was already in the queue (or already tried); the nearest unseen one
/// wins, unknown distances last.
String? autoAcceptPick(List<QueueItem> open, Set<String> seen, {required bool busy}) {
  if (busy) return null;
  QueueItem? best;
  for (final r in open) {
    if (seen.contains(r.id)) continue;
    if (best == null || (r.awayKm ?? double.infinity) < (best.awayKm ?? double.infinity)) best = r;
  }
  return best?.id;
}

/// Whether the partner may counter-offer on this request.
bool canCounterOffer({required bool requestOfferMe, required bool allowOfferMe}) => requestOfferMe && allowOfferMe;
