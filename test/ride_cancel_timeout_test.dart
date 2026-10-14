// The rider's cancellation request (migration 0191): how long it waits,
// when it counts as not answered, and that a lapse is not a decline.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_cancel.dart';
import 'package:get_ride/src/data/models.dart';

RideRequest _ride(Map<String, dynamic> extra) =>
    RideRequest({'id': 'r1', 'rider_id': 'me', 'partner_id': 'd1', 'status': 'on_trip', 'fare': 20, ...extra});

void main() {
  final now = DateTime.utc(2026, 10, 14, 12, 0, 0);
  const c = CancelRequestConfig();

  test('settings read as the server returns them', () {
    final read = CancelRequestConfig.fromJson({'timeoutSeconds': 90, 'openTicket': false});
    expect(read.timeout, const Duration(seconds: 90));
    expect(read.openTicket, isFalse);
    expect(CancelRequestConfig.fromJson(read.toJson()), read);
    expect(CancelRequestConfig.fromJson(null), CancelRequestConfig.standard);
    expect(CancelRequestConfig.fromJson({'timeoutSeconds': 5}).timeout, const Duration(seconds: 30));
  });

  test('a pending request counts down, then is not answered', () {
    final asked = _ride({
      'cancel_requested_at': now.subtract(const Duration(seconds: 55)).toIso8601String(),
      'cancel_requested_by': 'rider',
    });
    expect(riderCancelWaitLeft(asked, now, c), const Duration(seconds: 65));
    expect(cancelWaitText(const Duration(seconds: 65)), '1:05');
    expect(riderCancelUnanswered(asked, now, c), isFalse);
    expect(riderCancelUnanswered(asked, now.add(const Duration(seconds: 70)), c), isTrue);
  });

  test('a request the server lapsed shows its options for a while', () {
    final lapsed = _ride({
      'cancel_request_outcome': 'expired',
      'cancel_request_outcome_by': 'rider',
      'cancel_request_outcome_at': now.subtract(const Duration(minutes: 1)).toIso8601String(),
    });
    expect(riderCancelUnanswered(lapsed, now, c), isTrue);
    expect(riderCancelUnanswered(lapsed, now.add(unansweredShownFor), c), isFalse);
    final driverAsked = _ride({'cancel_request_outcome': 'expired', 'cancel_request_outcome_by': 'partner'});
    expect(riderCancelUnanswered(driverAsked, now, c), isFalse);
    final declined = _ride({'cancel_request_outcome': 'declined', 'cancel_request_outcome_by': 'rider'});
    expect(riderCancelUnanswered(declined, now, c), isFalse);
  });

  test('a lapse is not reported as the driver declining', () {
    final before = _ride({'cancel_requested_at': now.toIso8601String(), 'cancel_requested_by': 'rider'});
    expect(riderCancelDeclined(before, _ride({'cancel_request_outcome': 'declined'})), isTrue);
    expect(riderCancelDeclined(before, _ride({'cancel_request_outcome': 'expired'})), isFalse);
  });

  test('nothing once the ride has ended', () {
    final ended = _ride({
      'status': 'completed',
      'cancel_requested_at': now.subtract(const Duration(minutes: 5)).toIso8601String(),
      'cancel_requested_by': 'rider',
    });
    expect(riderCancelWaitLeft(ended, now, c), isNull);
    expect(riderCancelUnanswered(ended, now, c), isFalse);
  });
}
