import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/support_media.dart';

void main() {
  test('photo and voice-note rows parse, and say what they are', () {
    final photo = RideMessage.fromRow({
      'id': 'm1',
      'request_id': 'r1',
      'sender_id': 'u1',
      'sender_role': 'rider',
      'type': 'image',
      'body': '  Gate B  ',
      'media_path': 'r1/image-1-ab.jpg',
    })!;
    expect(photo.type, RideMessageType.image);
    expect(photo.hasMedia, isTrue);
    expect(photo.caption, 'Gate B');
    expect(photo.summary, 'Photo: Gate B');

    final bare = RideMessage.fromRow({
      'id': 'm2',
      'sender_role': 'partner',
      'type': 'image',
      'media_path': 'r1/image-2-cd.jpg',
    })!;
    expect(bare.caption, isNull);
    expect(bare.summary, 'Sent a photo');

    final voice = RideMessage.fromRow({
      'id': 'm3',
      'sender_role': 'partner',
      'type': 'audio',
      'media_path': 'r1/audio-3-ef.m4a',
      'media_duration': 7.3,
    })!;
    expect(voice.type, RideMessageType.audio);
    expect(voice.mediaDuration, const Duration(milliseconds: 7300));
    expect(voice.summary, 'Sent a voice note');
    expect(voice.copyWith(status: RideMessageStatus.read).mediaPath, 'r1/audio-3-ef.m4a');

    final noFile = RideMessage.fromRow({'id': 'm4', 'sender_role': 'rider', 'type': 'audio'})!;
    expect(noFile.hasMedia, isFalse);
  });

  test('files go in the ride\'s own folder with the right type', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    expect(rideChatMediaPath('r1', RideMessageType.image, 'JPG', at, 'ab12'), 'r1/image-1700000000000-ab12.jpg');
    expect(rideChatMediaPath('r1', RideMessageType.audio, 'm4a', at, 'cd34'), 'r1/audio-1700000000000-cd34.m4a');
    expect(rideChatContentType(RideMessageType.image, 'jpeg'), 'image/jpeg');
    expect(rideChatContentType(RideMessageType.image, 'heic'), 'image/heic');
    expect(rideChatContentType(RideMessageType.audio, 'm4a'), 'audio/mp4');
    expect(rideChatContentType(RideMessageType.audio, 'webm'), 'audio/webm');
    expect(rideChatContentType(RideMessageType.audio, 'wav'), 'audio/wav');
    expect(supportContentType('audio', 'm4a'), 'audio/mp4');
    expect(supportContentType('audio', 'webm'), 'audio/webm');
  });

  test('photo checks, voice-note lengths', () {
    expect(ridePhotoProblem(0), isNotNull);
    expect(ridePhotoProblem(rideChatMediaMaxBytes + 1), 'Choose a photo under 15 MB.');
    expect(ridePhotoProblem(2048), isNull);

    expect(formatVoiceDuration(const Duration(seconds: 7)), '0:07');
    expect(formatVoiceDuration(const Duration(seconds: 102)), '1:42');
    expect(formatVoiceDuration(-const Duration(seconds: 3)), '0:00');

    expect(rideVoiceNoteSeconds(const Duration(milliseconds: 7260)), 7.3);
    expect(rideVoiceNoteSeconds(const Duration(minutes: 9)), 300, reason: 'no longer than the database takes');
    expect(rideVoiceNoteMax, const Duration(minutes: 5));
  });
}
