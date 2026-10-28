// Who compares the faces and who reads the card (migration 0283): the
// settings as dispatch_verify_config gives them, why a face isn't checked,
// the provider after the score, and when Google Vision reads the ID.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/signin_checks.dart';

void main() {
  test('the face match in words, with who gave it', () {
    expect(faceMatchText('match', 82.4, provider: 'self_hosted'), '82% match · NAS');
    expect(faceMatchText('match', 91, provider: 'aws'), '91% match · AWS');
    expect(faceMatchText('no_match', 12, provider: 'aws'), 'Faces differ: 12% match · AWS');
    expect(faceMatchText('error', null, provider: 'self_hosted'), "Couldn't check · NAS");
    expect(faceMatchText('match', 71, provider: 'browser'), '71% match · in-browser');
    expect(
      faceMatchText('not_checked', null, reason: 'no_aws_key', browserNext: true),
      'Not checked · No AWS key yet · in-browser check next',
    );
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

  test('the orders: saved, else 0283\'s choice; moved, switched, in words', () {
    const legacy = IdentityConfig(faceProvider: 'self_hosted', idRead: 'vision');
    expect(legacy.faceOrder, const [OrderSlot('nas', true), OrderSlot('aws', false), OrderSlot('browser', true)]);
    expect(orderText(legacy.idReaders, idReaderWords), 'Google Vision, then Phone, then NAS');
    final c = IdentityConfig.fromJson({
      'faceProvider': 'aws',
      'faceOrder': [
        {'id': 'browser', 'on': false},
        {'id': 'nope'},
        {'id': 'aws'},
        {'id': 'browser', 'on': true},
      ],
      'idReaders': [
        {'id': 'phone', 'on': true},
        {'id': 'nas', 'on': true},
        {'id': 'vision', 'on': false},
      ],
      'faceLowScore': 200,
      'nasReader': true,
    });
    expect(c.faceOrder.map((x) => '$x'), ['browser:false', 'aws:true', 'nas:false'], reason: 'a missing one joins as 0283 had it');
    expect(c.browserOn, isFalse);
    expect(c.visionOn, isFalse);
    expect(c.faceLowScore, 95, reason: 'kept to 30..95');
    expect(orderText(c.faceOrder, faceOrderWords), 'AWS');
    expect(orderText(toggledSlot(c.faceOrder, 'aws', false), faceOrderWords), 'Off');
    final moved = movedSlot(c.faceOrder, 'nas', -1);
    expect(moved.map((x) => x.id), ['browser', 'nas', 'aws']);
    expect(movedSlot(moved, 'browser', -1), moved, reason: 'the first stays first');
    expect(const IdentityConfig().faceOrder.map((x) => x.id), ['aws', 'nas', 'browser']);
  });

  test('why no server can check a face, from the order', () {
    IdentityConfig cfg(List<OrderSlot> o, {bool aws = false, bool server = false}) =>
        IdentityConfig(savedFaceOrder: o, awsKey: aws, faceServer: server);
    const both = [OrderSlot('aws', true), OrderSlot('nas', true), OrderSlot('browser', true)];
    expect(cfg(both).faceUnusable, 'no_provider');
    expect(cfg(both, server: true).faceUnusable, isNull);
    expect(cfg(const [OrderSlot('aws', false), OrderSlot('nas', true)]).faceUnusable, 'no_server');
    expect(cfg(const [OrderSlot('aws', false), OrderSlot('nas', false), OrderSlot('browser', true)]).faceUnusable, 'off');
  });

  test('when Google Vision may read, walking the order', () {
    const read = (name: 'AINA BINTI AHMAD', ic: '880202-10-1234', expiry: null);
    IdentityConfig cfg(List<OrderSlot> o) => IdentityConfig(savedIdReaders: o);
    const phoneNasVision = [OrderSlot('phone', true), OrderSlot('nas', true), OrderSlot('vision', true)];
    expect(visionReadNeededFor(cfg(phoneNasVision), read), isFalse, reason: 'the phone read it');
    expect(visionReadNeededFor(cfg(phoneNasVision), null), isTrue, reason: 'the server says when the NAS has it');
    expect(visionReadNeededFor(cfg(const [OrderSlot('vision', true), OrderSlot('phone', true)]), read), isTrue);
    expect(visionReadNeededFor(const IdentityConfig(), null), isFalse, reason: 'Google Vision off by default');
  });

  test('a sign-in check needs a closer look below the set match', () {
    expect(signInFaceCloser('match', 55), isTrue);
    expect(signInFaceCloser('match', 55, lowScore: 50), isFalse);
    expect(signInFaceCloser('no_match', 0), isTrue);
    expect(signInFaceCloser('no_face', null), isTrue);
    expect(signInFaceCloser('not_checked', null), isFalse, reason: 'the admin compares by eye');
    expect(readSourceText('nas'), 'the office NAS');
  });
}
