/// Context a ride request row carries for the admin rides and fraud views
/// (Expo `gatherRequestMetadata`): the pickup's geography, the rider's public
/// IP, gender and photo. Every field is best effort, so only the known ones
/// are written.
library;

import '../data/geo_service.dart';
import 'session_telemetry.dart';

Map<String, Object> rideRequestMetadata({AreaInfo? area, String? ipAddress, String? gender, String? riderPhoto}) {
  String? s(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
  final photo = s(riderPhoto);
  final fields = <String, String?>{
    'country': s(area?.country),
    'state': s(area?.state),
    'city': s(area?.city),
    'suburb': s(area?.suburb),
    'full_address': s(area?.address),
    'ip_address': s(ipAddress),
    'gender': s(gender),
    // A data: URL or storage path means nothing to whoever reads the row.
    'rider_photo': photo != null && photo.startsWith('http') ? photo : null,
  };
  return {
    for (final e in fields.entries)
      if (e.value != null) e.key: e.value!,
  };
}

/// The optional column an insert error says the database lacks, if it is one
/// still in the row; null means the error is real. A bare mention of `stops`
/// counts too, as that is how a pre-0098 database reports it.
String? droppableRideColumn(String error, Set<String> optional, Iterable<String> rowKeys) {
  final col = missingColumn(error) ?? (error.contains('stops') ? 'stops' : null);
  return col != null && optional.contains(col) && rowKeys.contains(col) ? col : null;
}
