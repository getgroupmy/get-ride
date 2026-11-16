// The driver toolbar's reveal rule (lib/src/features/partner/partner_toolbar.dart):
// the shortcuts show only when open and not force-collapsed by a request.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/partner/partner_toolbar.dart';

void main() {
  test('shows only when open and not force-collapsed', () {
    expect(partnerToolbarShowsActions(open: true, forceCollapsed: false), isTrue);
    expect(partnerToolbarShowsActions(open: false, forceCollapsed: false), isFalse);
    expect(partnerToolbarShowsActions(open: true, forceCollapsed: true), isFalse,
        reason: 'a ride request keeps the shortcuts tucked away even if opened');
    expect(partnerToolbarShowsActions(open: false, forceCollapsed: true), isFalse);
  });
}
