@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/backend_lookup_io.dart';

// A local HTTPS server stands in for the backend, with certificates from a
// throwaway test CA made with openssl for the run: the pinned client must
// reach it by IP while still checking the certificate against the backend's
// name.
//
// The certificates are made the way a public CA makes them (a CA that says
// it is one, server certificates marked for TLS server use, SHA-256), from
// this file's own config so the result does not depend on the machine's
// openssl.cnf or on whether `openssl` is OpenSSL or LibreSSL. macOS and iOS
// check all of that, Linux only the chain and the name.
late String _dir;

Future<void> _makeCerts() async {
  _dir = (await Directory.systemTemp.createTemp('pinned_tls')).path;
  Future<void> run(List<String> args) async {
    final r = await Process.run('openssl', args, workingDirectory: _dir);
    if (r.exitCode != 0) throw StateError('openssl ${args.first}: ${r.stderr}');
  }

  await File('$_dir/ca.cnf').writeAsString('''
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = Test CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
''');
  await run([
    'req',
    '-x509',
    '-config',
    'ca.cnf',
    '-newkey',
    'rsa:2048',
    '-sha256',
    '-nodes',
    '-keyout',
    'ca.key',
    '-out',
    'ca.pem',
    '-days',
    '2',
  ]);
  for (final n in ['api.example.test', 'other.example.test']) {
    await File('$_dir/$n.cnf').writeAsString('''
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $n
[v3_server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$n
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
''');
    await run([
      'req',
      '-config',
      '$n.cnf',
      '-newkey',
      'rsa:2048',
      '-sha256',
      '-nodes',
      '-keyout',
      '$n.key',
      '-out',
      '$n.csr',
    ]);
    await run([
      'x509',
      '-req',
      '-in',
      '$n.csr',
      '-CA',
      'ca.pem',
      '-CAkey',
      'ca.key',
      '-CAcreateserial',
      '-sha256',
      '-out',
      '$n.pem',
      '-days',
      '2',
      '-extfile',
      '$n.cnf',
      '-extensions',
      'v3_server',
    ]);
  }
}

Future<HttpServer> _serve(String name) async {
  final ctx = SecurityContext()
    ..useCertificateChain('$_dir/$name.pem')
    ..usePrivateKey('$_dir/$name.key');
  final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
  server.listen((req) {
    req.response
      ..write('ok ${req.headers.host}')
      ..close();
  });
  return server;
}

void main() {
  late SecurityContext trust;
  setUpAll(() async {
    await _makeCerts();
    trust = SecurityContext(withTrustedRoots: false)..setTrustedCertificates('$_dir/ca.pem');
  });
  tearDownAll(() => Directory(_dir).delete(recursive: true));

  test('a name the DNS cannot find is reached at the pinned IP, certificate checked for the name', () async {
    final server = await _serve('api.example.test');
    addTearDown(() => server.close(force: true));
    final client = pinnedHttpClient('api.example.test', '127.0.0.1', context: trust);
    addTearDown(client.close);
    final res = await client.get(Uri.parse('https://api.example.test:${server.port}/auth/v1/health'));
    expect(res.statusCode, 200);
    expect(res.body, 'ok api.example.test');
  });

  test('an IP serving another name\'s certificate is refused, not talked to', () async {
    final server = await _serve('other.example.test');
    addTearDown(() => server.close(force: true));
    final client = pinnedHttpClient('api.example.test', '127.0.0.1', context: trust);
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('https://api.example.test:${server.port}/')), throwsA(anything));
  });

  test('other hosts are not pinned', () async {
    final server = await _serve('api.example.test');
    addTearDown(() => server.close(force: true));
    final client = pinnedHttpClient('api.example.test', '127.0.0.1', context: trust);
    addTearDown(client.close);
    // localhost resolves normally; its certificate is for another name, so
    // the normal path's own check refuses it -- the pin did not apply.
    await expectLater(client.get(Uri.parse('https://localhost:${server.port}/')), throwsA(anything));
  });
}
