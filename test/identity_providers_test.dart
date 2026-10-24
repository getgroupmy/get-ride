// Who compares the faces and who reads the card (migration 0283): the
// settings as dispatch_verify_config gives them, why a face isn't checked,
// the provider after the score, and when Google Vision reads the ID.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/signin_checks.dart';

void main() {
  test('the face match in words, with who gave it', () {
    expect(faceMatchText('match', 82.4, provider: 'self_hosted'), '82% match · self-hosted');
    expect(faceMatchText('match', 91, provider: 'aws'), '91% match · AWS');
    expect(faceMatchText('no_match', 12, provider: 'aws'), 'Faces differ: 12% match · AWS');
    expect(faceMatchText('error', null, provider: 'self_hosted'), "Couldn't check · self-hosted");
    expect(faceMatchText('not_checked', null, reason: 'no_aws_key'), 'Not checked · No AWS key yet');
    expect(faceMatchText(null, null, reason: 'no_server'), 'Not checked · Self-hosted server not set up');
    expect(faceMatchText('not_checked', null, reason: 'no_key'), 'Not checked · No AWS key yet', reason: '0281 said no_key');
    expect(faceMatchText(null, null, reason: 'something new'), 'Not checked');
  });

  test('the settings, AWS and the phone when unset', () {
    const none = IdentityConfig();
    expect([none.faceProvider, none.idRead, none.renewDays], ['aws', 'phone', 30]);
    final c = IdentityConfig.fromJson({
      'renewDays': 14,
      'faceProvider': 'self_hosted_aws',
      'idRead': 'phone_vision',
      'awsKey': false,
      'faceServer': true,
      'visionKey': false,
    });
    expect([c.faceProvider, c.idRead, c.renewDays], ['self_hosted_aws', 'phone_vision', 14]);
    expect(c.faceUnusable, isNull);
    expect(c.visionNote, contains('Cloud Vision (ID reading)'));
    expect(IdentityConfig.fromJson({'faceProvider': 'elsewhere', 'idRead': 'always'}).faceProvider, 'aws');
    expect(IdentityConfig.fromJson({'idRead': 'always'}).idRead, 'phone');
  });

  test('why no face can be checked as things are set up', () {
    IdentityConfig cfg(String face, {bool aws = false, bool server = false}) =>
        IdentityConfig(faceProvider: face, awsKey: aws, faceServer: server);
    expect(cfg('aws').faceUnusable, 'no_aws_key');
    expect(cfg('aws', aws: true).faceUnusable, isNull);
    expect(cfg('self_hosted', aws: true).faceUnusable, 'no_server');
    expect(cfg('self_hosted_aws').faceUnusable, 'no_provider');
    expect(cfg('self_hosted_aws', aws: true).faceUnusable, isNull);
    expect(cfg('off', aws: true, server: true).faceUnusable, 'off');
    expect(const IdentityConfig().faceUnusable, isNull, reason: 'keys not known: say nothing');
    expect(cfg('aws').faceNote, contains('Rekognition'));
  });

  test('when Google Vision reads the ID', () {
    const read = (name: 'AINA BINTI AHMAD', ic: '880202-10-1234', expiry: null);
    const blank = (name: null, ic: null, expiry: null);
    expect(visionReadNeeded('phone', null), isFalse);
    expect(visionReadNeeded('phone_vision', read), isFalse);
    expect(visionReadNeeded('phone_vision', blank), isTrue);
    expect(visionReadNeeded('phone_vision', null), isTrue, reason: 'web and desktop read nothing');
    expect(visionReadNeeded('vision', read), isTrue);
  });
}
