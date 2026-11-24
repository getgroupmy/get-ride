// Server monitor toggle (migration 0440): the per-provider `monitor` flag
// flips on/off and survives a write + re-read of the api_providers JSON.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/security/api_keys_logic.dart';

void main() {
  test('monitor is off by default and flips on then off', () {
    final list = [const ApiProviderDef(id: 'ekyc', name: 'GET eKYC')];
    expect(providerMonitorOn(list.first), isFalse);

    final on = setProviderMonitor(list, 'ekyc', true);
    expect(providerMonitorOn(on.first), isTrue);

    final off = setProviderMonitor(on, 'ekyc', false);
    expect(providerMonitorOn(off.first), isFalse);
  });

  test('monitor survives a write + re-read of the providers JSON', () {
    final on = setProviderMonitor([const ApiProviderDef(id: 'umami', name: 'Umami')], 'umami', true);
    expect(on.first.toJson()['monitor'], isTrue);

    final round = parseProviders(providersToJson(on));
    expect(providerMonitorOn(round.first), isTrue);
  });

  test('setProviderMonitor leaves other providers and existing fields alone', () {
    final list = [
      const ApiProviderDef(id: 'ekyc', name: 'GET eKYC', description: 'ID checks', category: 'Identity'),
      const ApiProviderDef(id: 'google', name: 'Google'),
    ];
    final out = setProviderMonitor(list, 'ekyc', true);
    final ekyc = out.firstWhere((p) => p.id == 'ekyc');
    expect(ekyc.description, 'ID checks');
    expect(ekyc.category, 'Identity');
    expect(providerMonitorOn(out.firstWhere((p) => p.id == 'google')), isFalse);
  });

  test('the face match server is the built-in-watched provider', () {
    expect(builtinMonitorProviders.contains('face_match'), isTrue);
  });
}
