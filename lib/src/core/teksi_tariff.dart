// The TEKSI tariff a pickup is priced on (Expo `partner-teksi.tsx`, "Select
// tariff"): the two built-in tariffs, New and Old, picked by the driver after
// Start Pickup's checks. An operator's rate card (Admin → Meter Digital) wins
// over the driver's pick, as it does on the meter: the keys only choose
// between the built-in tariffs where nothing is configured. Pure.
import '../admin/screens/meterapp/meter_logic.dart';

enum TeksiTariff {
  newTariff('new', 'NEW', 'New Tariff'),
  oldTariff('old', 'OLD', 'Old Tariff');

  const TeksiTariff(this.id, this.badge, this.title);

  /// `new` / `old`, as Expo's `TariffType` and the route parameter.
  final String id;
  final String badge;
  final String title;

  /// The tariff's rates, from the built-in cards.
  MeterRates get rates => tariffRates[id]!;

  /// The fare structure, as the sheet and the trip summary print it.
  List<String> get lines => switch (this) {
    TeksiTariff.newTariff => const ['RM4 + RM1 / KM + RM0.30 / minute'],
    TeksiTariff.oldTariff => const [
      'a) RM4.00 per KM or part',
      'b) RM0.35 per 200 meters or',
      'c) RM0.35 per 36 seconds',
    ],
  };

  /// The fare structure under the estimate (Expo's trip summary and confirm).
  List<String> get summaryLines => switch (this) {
    TeksiTariff.newTariff => const ['RM4.00 base fare', '+ RM1.00 per KM', '+ RM0.30 per minute'],
    TeksiTariff.oldTariff => lines,
  };

  String get blurb => switch (this) {
    TeksiTariff.newTariff => 'Flat per-km and per-minute pricing. Simpler and predictable.',
    TeksiTariff.oldTariff => 'Standard regulated meter — increments by distance or time.',
  };

  /// The meter key's label (Expo `meter-digital`: OLD RATES / NEW RATES).
  String get keyLabel => '$badge RATES';

  /// `new` / `old` back to a tariff; anything else is none.
  static TeksiTariff? fromId(Object? id) => switch (id) {
    'new' => TeksiTariff.newTariff,
    'old' => TeksiTariff.oldTariff,
    _ => null,
  };
}

/// The meter's default tariff where nothing is picked (Expo starts on Old).
const defaultTeksiTariff = TeksiTariff.oldTariff;

/// Whether the driver's tariff keys apply: only on the built-in card. An
/// operator's card names its own rates and is not overridden.
bool tariffKeysApply(ResolvedMeterProfile card) => card.level == 'default';

/// The rates a hire bills on: the operator's card when one is configured,
/// else the driver's tariff ([defaultTeksiTariff] when none was picked).
MeterRates ratesForTariff(ResolvedMeterProfile card, TeksiTariff? tariff) =>
    tariffKeysApply(card) ? (tariff ?? defaultTeksiTariff).rates : card.profile.rates;

/// What the console names the rates by: the tariff on the built-in card,
/// else the card's own label or scope.
String tariffRateLabel(ResolvedMeterProfile card, TeksiTariff? tariff) {
  if (tariffKeysApply(card)) return (tariff ?? defaultTeksiTariff).title;
  final label = (card.profile.label ?? '').trim();
  return label.isNotEmpty ? label : card.scope;
}

/// The lines under an estimate: the tariff's structure on the built-in card,
/// else the operator card that will bill it.
List<String> tariffSummaryLines(ResolvedMeterProfile card, TeksiTariff? tariff) => tariffKeysApply(card)
    ? (tariff ?? defaultTeksiTariff).summaryLines
    : ['Rate card: ${tariffRateLabel(card, tariff)}'];
