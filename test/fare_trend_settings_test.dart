import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/security/fare_ai_logic.dart';

void main() {
  group('fare trend settings', () {
    test('off unless a positive percent; stored only when set', () {
      expect(FareTrendSettings.fromJson(null).isOff, isTrue);
      expect(FareTrendSettings.fromJson({'upPct': '25', 'downPct': 0}), const FareTrendSettings(upPct: 25));
      expect(FareTrendSettings.parse(''), isNull);
      expect(FareTrendSettings.parse('12.5%'), 12.5);
      expect(FareTrendSettings.parse('-3'), isNull);
      expect(defaultFareAiConfig.toJson().containsKey('trend'), isFalse);
      final c = defaultFareAiConfig.copyWith(trend: const FareTrendSettings(upPct: 25, downPct: 10));
      expect((c.toJson()['trend'] as Map)['upPct'], 25.0);
      expect((c.toJson()['trend'] as Map)['downPct'], 10.0);
      expect(normalizeFareAi(c.toJson()).trend, const FareTrendSettings(upPct: 25, downPct: 10));
    });
  });

  group('fare trend measure', () {
    final rows = [
      for (final (ai, std) in [(30, 20), (24, 20), (22, 20), (20, 20), (18, 20)])
        {'duration_min': ai, 'standard_duration_min': std},
      {'duration_min': 10, 'standard_duration_min': null},
    ];

    test('how far the AI sits from standard, and how often the settings would fire', () {
      final m = measureFareTrend(rows, const FareTrendSettings(upPct: 15, downPct: 5))!;
      expect(m.count, 5);
      expect(m.median, closeTo(10, 0.001));
      expect(m.p25, closeTo(0, 0.001));
      expect(m.p75, closeTo(20, 0.001));
      expect(m.upShare, closeTo(0.4, 0.001)); // +50%, +20%
      expect(m.downShare, closeTo(0.2, 0.001)); // -10%
    });

    test('nothing logged with a standard time: no measure', () {
      expect(measureFareTrend([{'duration_min': 10}], FareTrendSettings.off), isNull);
    });
  });

  test('the log shows the trend and why', () {
    expect(
      fareAiTrafficLines({
        'trend': {'direction': 'up', 'source': 'minutes', 'pct': 32.4, 'standard_min': 20, 'ai_min': 26.5},
      }),
      ['Fare trend: up arrows (AI +32% vs standard 20 min)'],
    );
    expect(
      fareAiTrafficLines({
        'trend': {'direction': null, 'source': 'fare_range', 'ai_min': 20},
      }),
      ['Fare trend: no arrows (AI fare range)'],
    );
  });

  test('arrow colours: hex only, per arrow and mode, blank keeps the default', () {
    expect(FareTrendSettings.hex('#e02424'), '#E02424');
    expect(FareTrendSettings.hex('0f0'), '#00FF00');
    expect(FareTrendSettings.hex('red'), isNull);
    var t = FareTrendSettings.off.withColor('upColorLight', 'ff0000').withColor('downColorDark', '#22c55e');
    expect(t.upColorLight, '#FF0000');
    expect(t.downColorDark, '#22C55E');
    expect(t.upColorDark, isNull);
    expect(t.isOff, isFalse, reason: 'a colour alone is stored');
    t = t.withColor('upColorLight', '');
    expect(t.upColorLight, isNull);
    final round = normalizeFareAi(defaultFareAiConfig.copyWith(trend: t).toJson()).trend;
    expect(round, t);
    expect(round.withUp(20).downColorDark, '#22C55E', reason: 'a threshold edit keeps the colours');
  });
}
