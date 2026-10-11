import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/ble.dart';

void main() {
  test('the phone\'s one scan runs while anyone needs it and stops with the last', () async {
    final calls = <String>[];
    final scans = BleScanCoordinator(() async => calls.add('start'), () async => calls.add('stop'));
    await scans.acquire(); // the printer sheet
    await scans.acquire(); // the reader finding itself after a drop
    expect(calls, ['start']);
    await scans.release(); // the reader found
    expect(calls, ['start'], reason: 'the printer sheet is still scanning');
    await scans.release();
    expect(calls, ['start', 'stop']);
    await scans.release();
    expect(calls, ['start', 'stop'], reason: 'an extra release is harmless');
  });

  test('a scan that fails to start leaves nobody counted', () async {
    var fail = true;
    final calls = <String>[];
    final scans = BleScanCoordinator(() async {
      if (fail) throw StateError('Bluetooth is off');
      calls.add('start');
    }, () async => calls.add('stop'));
    await expectLater(scans.acquire(), throwsStateError);
    expect(scans.users, 0);
    fail = false;
    await scans.acquire();
    expect(calls, ['start']);
  });

  test('a second user waits for a start already on its way', () async {
    final calls = <String>[];
    final scans = BleScanCoordinator(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      calls.add('start');
    }, () async => calls.add('stop'));
    final first = scans.acquire();
    await scans.acquire();
    expect(calls, ['start']);
    await first;
  });
}
