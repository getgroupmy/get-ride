// Ride messages read aloud to the driver (reliability Phase C): eyes stay on
// the road while the passenger's "I'm at the gate" still gets through. What is
// said, and which messages are said, is decided here. Pure.
import 'ride_chat.dart';

/// The longest message read in full; longer ones are cut at a word.
const rideReadAloudMaxChars = 200;

/// What is said for [m], sent by [sender] ("Aina", "Your passenger").
String rideMessageSpeech(RideMessage m, String sender) {
  final who = sender.trim().isEmpty ? 'Your passenger' : sender.trim();
  switch (m.type) {
    case RideMessageType.location:
      return '$who shared a location.';
    case RideMessageType.image:
      return '$who sent a photo.';
    case RideMessageType.audio:
      return '$who sent a voice note.';
    case RideMessageType.text:
    case RideMessageType.quick:
      final body = _clip((m.body ?? '').replaceAll(RegExp(r'\s+'), ' ').trim());
      return body.isEmpty ? '$who sent a message.' : '$who says: $body';
  }
}

String _clip(String s) {
  if (s.length <= rideReadAloudMaxChars) return s;
  final cut = s.substring(0, rideReadAloudMaxChars);
  final space = cut.lastIndexOf(' ');
  return '${(space > rideReadAloudMaxChars ~/ 2 ? cut.substring(0, space) : cut).trimRight()}…';
}

/// The messages of [thread] still to be read: from the other side, and not
/// in [heard]. The first thread a trip screen sees is history, not news: the
/// caller marks it all heard without reading it.
List<RideMessage> rideMessagesToReadAloud(
  List<RideMessage> thread, {
  required String? me,
  required Set<String> heard,
}) => [
  for (final m in thread)
    if (m.senderId != me && !heard.contains(m.id)) m,
];
