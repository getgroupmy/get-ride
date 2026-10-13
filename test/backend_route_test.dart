import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/backend_route.dart';

void main() {
  const direct = 'https://rqlavogkgywxspuxgiwk.supabase.co';
  const fallback = 'https://api.getride.my';

  test('stored file links follow the active address; others are left alone', () {
    const avatar = '$direct/storage/v1/object/public/avatars/u1.jpg?t=1';
    expect(onActiveBackend(avatar, direct, direct), avatar);
    expect(onActiveBackend(avatar, direct, fallback), '$fallback/storage/v1/object/public/avatars/u1.jpg?t=1');
    const elsewhere = 'https://tile.openstreetmap.org/1/1/1.png';
    expect(onActiveBackend(elsewhere, direct, fallback), elsewhere);
    expect(onActiveBackend('not a url', direct, fallback), 'not a url');
  });

  test('the active address is the one set at launch', () {
    expect(activeBackendUrl(direct), direct);
    expect(onBackendFallback(direct), isFalse);
    setActiveBackendUrl(fallback);
    expect(activeBackendUrl(direct), fallback);
    expect(onBackendFallback(direct), isTrue);
    setActiveBackendUrl(direct, pinnedIp: '104.18.1.1');
    expect(onBackendFallback(direct), isFalse);
    expect(activeBackendPinnedIp, '104.18.1.1');
    setActiveBackendUrl(direct);
    expect(activeBackendPinnedIp, isNull);
  });

  test('Settings says which address and, when a resolver found it, which IP', () {
    setActiveBackendUrl(direct);
    expect(backendRouteText(direct), 'rqlavogkgywxspuxgiwk.supabase.co');
    setActiveBackendUrl(fallback);
    expect(backendRouteText(direct), 'rqlavogkgywxspuxgiwk.supabase.co via api.getride.my');
    setActiveBackendUrl(direct, pinnedIp: '104.18.1.1');
    expect(backendRouteText(direct), 'rqlavogkgywxspuxgiwk.supabase.co (104.18.1.1, DNS over HTTPS)');
    setActiveBackendUrl(direct);
  });
}
