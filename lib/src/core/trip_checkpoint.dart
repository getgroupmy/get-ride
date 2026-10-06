/// Where the driver was at a trip milestone, stamped on the ride row for the
/// admin fraud checks (`partner_arrive_*` against the pickup,
/// `partner_drop_*` against the drop-off and the rider's own drop fix).
///
/// The accept checkpoint is written by the claim itself (`partner_accept_*`);
/// these are the two the trip screen records afterwards.
enum TripCheckpoint {
  arrive,
  drop;

  String get latColumn => 'partner_${name}_lat';
  String get lngColumn => 'partner_${name}_lng';
}

/// The row patch for [checkpoint], or null when there is no usable fix — a
/// missing checkpoint is better evidence than a made-up one, so nothing is
/// written rather than a zero or a stale guess.
Map<String, double>? checkpointPatch(TripCheckpoint checkpoint, double? lat, double? lng) {
  if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) return null;
  if (lat.abs() > 90 || lng.abs() > 180) return null;
  return {checkpoint.latColumn: lat, checkpoint.lngColumn: lng};
}
