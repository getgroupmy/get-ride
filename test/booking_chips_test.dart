// The ride sheet's booking-row chips (Now, Later, Passengers, Luggage, custom)
// as Admin → Display Settings → Booking Row arranges them.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/booking_chips.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart' show mergeDisplaySettings, defaultDisplaySettings;

void main() {
  const ids = [bookingChipNowId, bookingChipLaterId, bookingChipPassengersId, bookingChipLuggageId];

  test('defaults: the four built-ins, in order, themed', () {
    final chips = resolveBookingChips(const {});
    expect(chips.map((c) => c.id), ids);
    expect(chips.map((c) => c.kind), ids); // a built-in's kind is its id
    expect(chips.map((c) => c.label), ['Now', 'Later', 'Passengers', 'Luggage']);
    expect(chips.every((c) => c.themed && !c.custom), isTrue);
    expect(chips.firstWhere((c) => c.id == bookingChipNowId).iconName, 'Clock');
  });

  test('the blob carries a bookingChips slot', () {
    expect(defaultDisplaySettings()['bookingChips'], isA<Map>());
    expect(mergeDisplaySettings(const {})['bookingChips'], isA<Map>());
  });

  test('rename, re-icon, hide and reorder a built-in', () {
    var s = <String, dynamic>{};
    s = renameBookingChip(s, bookingChipPassengersId, 'Pax');
    s = setBookingChipIcon(s, bookingChipPassengersId, 'User');
    s = setBookingChipVisibility(s, bookingChipNowId, false);
    s = moveBookingChip(s, bookingChipLuggageId, -3); // luggage to the front
    final chips = resolveBookingChips(s);
    expect(chips.map((c) => c.id), isNot(contains(bookingChipNowId)), reason: 'Now hidden');
    expect(chips.first.id, bookingChipLuggageId, reason: 'moved to front');
    expect(chips.firstWhere((c) => c.id == bookingChipPassengersId).label, 'Pax');
    // Renaming back to the default drops the override.
    s = renameBookingChip(s, bookingChipPassengersId, 'Passengers');
    expect((s['bookingChips'] as Map)['renames'], isNot(contains(bookingChipPassengersId)));
  });

  test('text and fill colours, and clearing them back to theme', () {
    var s = <String, dynamic>{};
    s = setBookingChipColor(s, bookingChipLuggageId, 'bg', '#1670E6');
    s = setBookingChipColor(s, bookingChipLuggageId, 'fg', '#FFFFFF');
    final c = resolveBookingChips(s).firstWhere((x) => x.id == bookingChipLuggageId);
    expect(c.bg, '#1670E6');
    expect(c.fg, '#FFFFFF');
    expect(c.themed, isFalse);
    s = setBookingChipColor(s, bookingChipLuggageId, 'bg', '');
    s = setBookingChipColor(s, bookingChipLuggageId, 'fg', null);
    expect(resolveBookingChips(s).firstWhere((x) => x.id == bookingChipLuggageId).themed, isTrue);
  });

  test('a custom chip is added, coloured, and removed cleanly', () {
    var s = <String, dynamic>{};
    s = addCustomBookingChip(s, 'Pets', id: 'c1', icon: 'Heart');
    s = setBookingChipColor(s, 'c1', 'bg', '#22C55E');
    var custom = resolveBookingChips(s).where((c) => c.custom).toList();
    expect(custom.map((c) => c.label), ['Pets']);
    expect(custom.single.bg, '#22C55E');
    expect(custom.single.kind, customBookingChipKind);
    // Removing it clears its row and any colour it carried.
    s = removeCustomBookingChip(s, 'c1');
    expect(resolveBookingChips(s).where((c) => c.custom), isEmpty);
  });

  test('normalize tolerates junk', () {
    final s = {'bookingChips': {'hidden': 'nope', 'customItems': [{'id': 2}, {'id': 'ok', 'label': 'OK'}], 'fg': {'now': 7}}};
    final chips = resolveBookingChips(s);
    expect(chips.map((c) => c.id), containsAll(ids)); // junk ignored, built-ins intact
    expect(chips.where((c) => c.custom).map((c) => c.label), ['OK']);
  });
}
