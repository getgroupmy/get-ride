// A position fix as a map follows it (core/follow_motion.dart): where the
// device is, when the GPS took the fix, how far out it may be, and the velocity
// the chip measured with it.
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// A fix from the device's location stream: where it is, when the GPS took the
/// fix, how far out it may be (metres), and the velocity vector the chip reports
/// with it — speed (m/s) and course (the bearing of travel, degrees). Each of
/// the last four is null when the GPS has none to give.
///
/// A map carries the fix forward by the speed and course to where the device is
/// now, far cleaner than reconstructing them from how the point moved; the time
/// between two fixes turns the change in speed into the braking or acceleration
/// to carry it forward with.
typedef LiveFix = ({LatLng at, double? speed, double? course, DateTime? time, double? accuracy});

/// A course the GPS itself puts this far out (degrees, its own estimate) is not
/// one to carry a fix along: at a crawl the bearing swings about.
const courseTrustDegrees = 45.0;

/// The fix a map follows, from a platform position, keeping only a velocity the
/// platform really measured. The two platforms say "none" differently: iOS
/// reports an unknown course as −1 and simply leaves an unknown speed out;
/// Android leaves either out — and a value left out arrives as a 0.0
/// placeholder (which would read as "stopped" or "heading due north") with its
/// `has…` flag false. Pure; see test/driver_follow_test.dart.
LiveFix liveFixOf(Position p) => (
  at: LatLng(p.latitude, p.longitude),
  speed: p.hasSpeed && p.speed.isFinite && p.speed >= 0 ? p.speed : null,
  course: p.hasHeading &&
          p.heading.isFinite &&
          p.heading >= 0 &&
          !(p.hasHeadingAccuracy && (p.headingAccuracy < 0 || p.headingAccuracy > courseTrustDegrees))
      ? p.heading % 360
      : null,
  time: p.timestamp,
  accuracy: p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : null,
);
