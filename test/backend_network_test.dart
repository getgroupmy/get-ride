import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_branding.dart';
import 'package:get_ride/src/core/backend_network.dart';

void main() {
  const direct = 'https://rqlavogkgywxspuxgiwk.supabase.co';

  group('addresses', () {
    test('normalised to a bare https host; anything else refused', () {
      expect(normalizeBackendUrl('api2.getride.my'), 'https://api2.getride.my');
      expect(normalizeBackendUrl(' https://API2.getride.my/ '), 'https://api2.getride.my');
      expect(normalizeBackendUrl('https://api2.getride.my:8443'), 'https://api2.getride.my:8443');
      expect(normalizeBackendUrl('https://api2.getride.my:443'), 'https://api2.getride.my');
      for (final bad in [
        '',
        'http://api2.getride.my',
        'https://api2.getride.my/rest/v1',
        'https://api2.getride.my?x=1',
        'https://user:pw@api2.getride.my',
        'ftp://api2.getride.my',
      ]) {
        expect(normalizeBackendUrl(bad), isNull, reason: bad);
      }
    });

    test('only the project\'s own host or getride.my may carry the app\'s traffic', () {
      expect(isAllowedBackend(direct, direct), isTrue);
      expect(isAllowedBackend('https://api.getride.my', direct), isTrue);
      expect(isAllowedBackend('https://getride.my', direct), isTrue);
      expect(isAllowedBackend('https://evil.com', direct), isFalse);
      expect(isAllowedBackend('https://getride.my.evil.com', direct), isFalse);
      expect(isAllowedBackend('https://notgetride.my', direct), isFalse);
      expect(isAllowedBackend('https://other.supabase.co', direct), isFalse);
    });

    test('candidates: own address, the admin\'s allowed ones, then the built-in second', () {
      const network = BackendNetwork(
        backends: ['https://api2.getride.my', 'https://evil.com', 'https://api.getride.my'],
      );
      expect(backendCandidates(direct, network), [direct, 'https://api2.getride.my', 'https://api.getride.my']);
      expect(backendCandidates(direct, BackendNetwork.none), [direct, 'https://api.getride.my']);
    });
  });

  group('DNS over HTTPS', () {
    test('query adds the name and type to the resolver', () {
      expect(
        dohQuery('https://1.1.1.1/dns-query', 'api.getride.my').toString(),
        'https://1.1.1.1/dns-query?name=api.getride.my&type=A',
      );
    });

    test('answers: A records only, CNAME steps skipped, errors empty', () {
      final ok = {
        'Status': 0,
        'Answer': [
          {'name': 'x', 'type': 5, 'data': 'cdn.example.'},
          {'name': 'cdn', 'type': 1, 'data': '104.18.1.1'},
          {'name': 'cdn', 'type': 1, 'data': '104.18.2.2'},
          {'name': 'cdn', 'type': 1, 'data': '104.18.1.1'},
          {'name': 'cdn', 'type': 1, 'data': '999.1.1.1'},
        ],
      };
      expect(parseDohAnswer(ok), ['104.18.1.1', '104.18.2.2']);
      expect(parseDohAnswer({'Status': 3}), isEmpty);
      expect(parseDohAnswer({'Status': 0}), isEmpty);
      expect(parseDohAnswer('nonsense'), isEmpty);
    });

    test('resolver addresses: https with a path, no query', () {
      expect(normalizeDohUrl('https://1.1.1.1/dns-query'), 'https://1.1.1.1/dns-query');
      expect(normalizeDohUrl('http://1.1.1.1/dns-query'), isNull);
      expect(normalizeDohUrl('https://1.1.1.1/dns-query?name=x'), isNull);
    });

    test('no resolvers set: the built-in ones', () {
      expect(BackendNetwork.none.resolvers, defaultDohResolvers);
      expect(const BackendNetwork(dohResolvers: ['https://9.9.9.9/dns-query']).resolvers, [
        'https://9.9.9.9/dns-query',
      ]);
    });
  });

  group('choosing', () {
    const candidates = [direct, 'https://api2.getride.my', 'https://api.getride.my'];

    test('the first the phone\'s DNS resolves, in order', () {
      expect(chooseBackend(candidates, resolves: (_) => true), const BackendChoice(direct));
      expect(
        chooseBackend(candidates, resolves: (c) => c == 'https://api.getride.my'),
        const BackendChoice('https://api.getride.my'),
      );
    });

    test('none resolves: the first a resolver found, pinned to its address', () {
      expect(
        chooseBackend(
          candidates,
          resolves: (_) => false,
          dohIps: {
            'https://api2.getride.my': ['104.18.1.1', '104.18.2.2'],
          },
        ),
        const BackendChoice('https://api2.getride.my', pinnedIp: '104.18.1.1'),
      );
    });

    test('nothing found anywhere (offline): the own address, unpinned', () {
      expect(chooseBackend(candidates, resolves: (_) => false), const BackendChoice(direct));
    });
  });

  group('stored settings', () {
    test('read from the row, junk dropped, capped, duplicates removed', () {
      final n = BackendNetwork.fromJson({
        'backends': [
          'api2.getride.my',
          'https://api2.getride.my/',
          'http://x',
          42,
          for (var i = 0; i < 9; i++) 'a$i.getride.my',
        ],
        'doh': ['https://1.1.1.1/dns-query', 'not a url'],
      });
      expect(n.backends.first, 'https://api2.getride.my');
      expect(n.backends, hasLength(backendNetworkMaxEntries));
      expect(n.dohResolvers, ['https://1.1.1.1/dns-query']);
      expect(BackendNetwork.fromJson(null), BackendNetwork.none);
      expect(BackendNetwork.fromJson('x'), BackendNetwork.none);
    });

    test('ride with the cached branding to the next launch', () {
      final row = {
        'network': {
          'backends': ['https://api2.getride.my'],
        },
      };
      final b = AppBranding.fromRow(row);
      expect(b.network.backends, ['https://api2.getride.my']);
      final again = AppBranding.fromRow(b.toJson());
      expect(again.network, b.network);
      expect(again, b);
      // A database without 0171: no network, nothing breaks.
      expect(AppBranding.fromRow(const {}).network, BackendNetwork.none);
    });
  });

  group('admin form', () {
    test('one entry per line (or comma), blanks skipped', () {
      final r = parseNetworkList('api2.getride.my\n\n https://api3.getride.my , ', normalizeBackendUrl);
      expect(r.entries, ['https://api2.getride.my', 'https://api3.getride.my']);
      expect(r.bad, isNull);
    });

    test('validation names the problem', () {
      expect(validateBackendNetwork('api2.getride.my', '', direct), isNull);
      expect(validateBackendNetwork('https://evil.com', '', direct), contains('must be under getride.my'));
      expect(validateBackendNetwork('https://api2.getride.my/rest', '', direct), contains('Not a backend address'));
      expect(validateBackendNetwork('', 'http://1.1.1.1/dns-query', direct), contains('Not a DNS-over-HTTPS'));
      expect(
        validateBackendNetwork([for (var i = 0; i < 6; i++) 'a$i.getride.my'].join('\n'), '', direct),
        contains('At most'),
      );
    });

    test('the saved value; empty lists leave nothing', () {
      expect(backendNetworkPatch('api2.getride.my', ''), {
        'backends': ['https://api2.getride.my'],
      });
      expect(backendNetworkPatch('', ''), isEmpty);
      expect(
        networkListText(['https://a.getride.my', 'https://b.getride.my']),
        'https://a.getride.my\nhttps://b.getride.my',
      );
    });
  });
}
