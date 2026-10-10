// Ride calls ringing the phone's own call screen (migration 0134): what a
// push or a call row rings, and what the call screen's presses mean.
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/call_ring.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/ride_call.dart';
import 'package:get_ride/src/data/call_ringer.dart';

void main() {
  group('a ride call push', () {
    test('rings the call it names, with the caller from the data or the title', () {
      expect(
        callRingFromPush({
          'type': 'ride_call',
          'call_id': 'c1',
          'request_id': 'r1',
          'caller_name': 'Aina',
          'role': 'partner',
          'title': 'Someone else is calling',
        }),
        const CallRing(callId: 'c1', requestId: 'r1', callerName: 'Aina', role: 'partner'),
      );
      expect(
        callRingFromPush({'type': 'ride_call', 'call_id': 'c1', 'request_id': 'r1', 'title': 'Ravi is calling'})
            ?.callerName,
        'Ravi',
      );
      expect(callRingFromPush({'type': 'ride_call', 'call_id': 'c1', 'request_id': 'r1'})?.callerName, 'GET.ride');
    });

    test('is nothing without a call and a ride, or for another kind of push', () {
      expect(callRingFromPush({'type': 'ride_call', 'call_id': 'c1'}), isNull);
      expect(callRingFromPush({'type': 'ride_call', 'request_id': 'r1', 'call_id': ' '}), isNull);
      expect(callRingFromPush({'type': 'ride_message', 'call_id': 'c1', 'request_id': 'r1'}), isNull);
    });

    test('a call that stopped ringing names the call to stop', () {
      expect(endedCallFromPush({'type': 'ride_call_end', 'call_id': 'c1'}), 'c1');
      expect(endedCallFromPush({'type': 'ride_call', 'call_id': 'c1'}), isNull);
    });

    test('tapping "Missed call" goes back to the trip', () {
      expect(pushRouteFor({'type': 'ride_call_end', 'request_id': 'r 1', 'role': 'partner'}), '/drive/trip/r%201');
      expect(pushRouteFor({'type': 'ride_call_end', 'request_id': 'r1', 'role': 'rider'}), '/ride/r1');
      expect(pushRouteFor({'type': 'ride_call_end'}), isNull);
    });
  });

  group('a call row', () {
    final now = DateTime.utc(2026, 10, 10, 12);
    RideCall row({String status = 'ringing', int secondsAgo = 10}) => RideCall({
      'id': 'c1',
      'request_id': 'r1',
      'caller_id': 'rider-1',
      'callee_id': 'driver-1',
      'caller_role': 'rider',
      'caller_name': 'Aina',
      'status': status,
      'created_at': now.subtract(Duration(seconds: secondsAgo)).toIso8601String(),
    });

    test('rings the callee for what is left of its 45 seconds', () {
      final ring = callRingFromCall(row(), 'driver-1', now)!;
      expect(ring.callerName, 'Aina');
      expect(ring.role, 'partner', reason: 'the callee of a rider is the driver');
      expect(ring.ringMillis, 35000);
      expect(ring.extra, {
        'type': 'ride_call',
        'call_id': 'c1',
        'request_id': 'r1',
        'caller_name': 'Aina',
        'role': 'partner',
      });
    });

    test('rings nobody else, and nothing that stopped or rang out', () {
      expect(callRingFromCall(row(), 'rider-1', now), isNull, reason: 'the caller');
      expect(callRingFromCall(row(), 'someone', now), isNull);
      expect(callRingFromCall(row(status: 'cancelled'), 'driver-1', now), isNull);
      expect(callRingFromCall(row(secondsAgo: 50), 'driver-1', now), isNull);
    });

    test('rings at least a moment and at most 45 seconds', () {
      expect(const CallRing(callId: 'c', requestId: 'r', callerName: 'x').ringMillis, 45000);
      expect(
        const CallRing(callId: 'c', requestId: 'r', callerName: 'x', ringFor: Duration(milliseconds: 10)).ringMillis,
        1000,
      );
      expect(
        const CallRing(callId: 'c', requestId: 'r', callerName: 'x', ringFor: Duration(minutes: 5)).ringMillis,
        45000,
      );
    });
  });

  test('the in-app call screen, answering when Accept was pressed on the phone', () {
    expect(rideCallRoute('c 1'), '/ride-call/c%201');
    expect(rideCallRoute('c1', answer: true), '/ride-call/c1?answer=1');
  });

  test("the phone's call screen is a voice call keyed by the call", () {
    final p = callKitParams(const CallRing(callId: 'c1', requestId: 'r1', callerName: 'Aina', role: 'partner'));
    expect(p.id, 'c1');
    expect(p.nameCaller, 'Aina');
    expect(p.type, 0);
    expect(p.duration, 45000);
    expect(p.extra?['request_id'], 'r1');
    expect(p.ios?.supportsVideo, false);
    expect(p.ios?.supportsHolding, false);
    expect(p.android?.ringtonePath, 'system_ringtone_default');
    expect(p.missedCallNotification?.isShowCallback, false);
  });

  test("the phone's presses, by call", () {
    const params = CallKitParams(id: 'plugin-id', extra: {'call_id': 'c1'});
    expect(ringActionFor(const CallEventActionCallAccept(params)), (RingAction.accept, 'c1'));
    expect(ringActionFor(const CallEventActionCallDecline(params)), (RingAction.decline, 'c1'));
    expect(ringActionFor(const CallEventActionCallEnded(params)), (RingAction.end, 'c1'));
    expect(ringActionFor(const CallEventActionCallTimeout('c1')), (RingAction.timeout, 'c1'));
    // Without our extra, the plugin's own id is the call.
    expect(ringActionFor(const CallEventActionCallAccept(CallKitParams(id: 'c2'))), (RingAction.accept, 'c2'));
    expect(ringActionFor(const CallEventActionCallToggleMute('c1', true)), isNull);
    expect(ringActionFor(null), isNull);
  });
}
