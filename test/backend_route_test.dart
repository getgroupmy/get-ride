import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/backend_route.dart';

void main() {
  const direct = 'https://rqlavogkgywxspuxgiwk.supabase.co';
  const fallback = 'https://api.getride.my';

  test('the project\'s own address unless it fails to resolve and the second does', () {
    expect(chooseBackendUrl(direct, directResolves: true, fallbackResolves: true), direct);
    expect(chooseBackendUrl(direct, directResolves: true, fallbackResolves: false), direct);
    expect(chooseBackendUrl(direct, directResolves: false, fallbackResolves: true), fallback);
    // Neither resolves (offline): stay put, the app's offline handling takes over.
    expect(chooseBackendUrl(direct, directResolves: false, fallbackResolves: false), direct);
  });

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
    setActiveBackendUrl(direct);
    expect(onBackendFallback(direct), isFalse);
  });
}
