import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/client_certificate_service.dart';

void main() {
  late Directory support;
  late ClientCertificateService service;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('hermes-client-cert-test');
    service = ClientCertificateService(supportDirectory: () async => support);
  });

  tearDown(() async {
    if (support.existsSync()) await support.delete(recursive: true);
  });

  Future<List<int>> fixture(String name) =>
      File('test/fixtures/$name').readAsBytes();

  test('importPemPair writes both PEM files under app support', () async {
    final config = await service.importPemPair(
      certificateBytes: await fixture('client-cert.pem'),
      privateKeyBytes: await fixture('client-key.pem'),
      label: 'fixture-client.pem',
    );

    expect(config.label, 'fixture-client.pem');
    expect(config.privateKeyPassword, isNull);
    expect(config.certificatePemPath, startsWith(support.path));
    expect(config.privateKeyPemPath, startsWith(support.path));
    expect(config.certificatePemPath, endsWith('certificate.pem'));
    expect(config.privateKeyPemPath, endsWith('private-key.pem'));

    final certificateFile = File(config.certificatePemPath);
    final privateKeyFile = File(config.privateKeyPemPath);
    expect(certificateFile.existsSync(), isTrue);
    expect(privateKeyFile.existsSync(), isTrue);
    expect(
      await certificateFile.readAsString(),
      contains('-----BEGIN CERTIFICATE-----'),
    );
    expect(
      await privateKeyFile.readAsString(),
      contains('-----BEGIN PRIVATE KEY-----'),
    );
  });

  test('importPemPair keeps an optional private-key password', () async {
    final config = await service.importPemPair(
      certificateBytes: await fixture('client-cert.pem'),
      privateKeyBytes: await fixture('client-key.pem'),
      password: 'key-password',
      label: 'fixture-client.pem',
    );

    expect(config.privateKeyPassword, 'key-password');
  });

  test('importPemPair rejects a non-PEM certificate', () async {
    await expectLater(
      service.importPemPair(
        certificateBytes: 'not a certificate'.codeUnits,
        privateKeyBytes: await fixture('client-key.pem'),
        label: 'broken.pem',
      ),
      throwsA(
        isA<ClientCertificateImportException>().having(
          (e) => e.message,
          'message',
          contains('not a PEM certificate'),
        ),
      ),
    );
  });

  test('importPkcs12 writes the leaf certificate plus its CA chain', () async {
    final config = await service.importPkcs12(
      bytes: await fixture('client-test.p12'),
      password: 'test-password',
      label: 'fixture-client.p12',
    );

    expect(config.label, 'fixture-client.p12');
    final certificatePem = await File(config.certificatePemPath).readAsString();
    final privateKeyPem = await File(config.privateKeyPemPath).readAsString();
    // The fixture contains a leaf certificate and its CA certificate.
    expect(
      '-----BEGIN CERTIFICATE-----'.allMatches(certificatePem),
      hasLength(2),
    );
    expect(certificatePem, startsWith('-----BEGIN CERTIFICATE-----'));
    expect(privateKeyPem, contains('-----BEGIN PRIVATE KEY-----'));
  });

  test(
    'importPkcs12 reports a wrong password as a user-facing error',
    () async {
      await expectLater(
        service.importPkcs12(
          bytes: await fixture('client-test.p12'),
          password: 'wrong-password',
          label: 'fixture-client.p12',
        ),
        throwsA(
          isA<ClientCertificateImportException>().having(
            (e) => e.message,
            'message',
            contains('password is incorrect'),
          ),
        ),
      );
    },
  );

  test(
    'importPkcs12 reports an unreadable file as a user-facing error',
    () async {
      await expectLater(
        service.importPkcs12(
          bytes: 'not a p12'.codeUnits,
          password: null,
          label: 'broken.p12',
        ),
        throwsA(
          isA<ClientCertificateImportException>().having(
            (e) => e.message,
            'message',
            contains('not a readable PKCS#12'),
          ),
        ),
      );
    },
  );
}
