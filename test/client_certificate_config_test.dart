import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/client_certificate.dart';
import 'package:hermes_android/core/models/connection.dart';

void main() {
  const config = ClientCertificateConfig(
    label: 'Hermes proxy',
    certificatePemPath: '/data/app/client-certs/a/certificate.pem',
    privateKeyPemPath: '/data/app/client-certs/a/private-key.pem',
    privateKeyPassword: 'secret',
  );

  group('ClientCertificateConfig', () {
    test('round-trips through JSON', () {
      final restored = ClientCertificateConfig.fromJson(config.toJson());

      expect(restored, config);
      expect(restored.hashCode, config.hashCode);
    });

    test('omits (and restores) a null key password', () {
      final withoutPassword = config.copyWith(clearPrivateKeyPassword: true);
      final json = withoutPassword.toJson();

      expect(json.containsKey('private_key_password'), isFalse);
      expect(ClientCertificateConfig.fromJson(json), withoutPassword);
      expect(withoutPassword.privateKeyPassword, isNull);
    });

    test('copyWith replaces only the requested fields', () {
      final updated = config.copyWith(label: 'Renamed');

      expect(updated.label, 'Renamed');
      expect(updated.certificatePemPath, config.certificatePemPath);
      expect(updated.privateKeyPemPath, config.privateKeyPemPath);
      expect(updated.privateKeyPassword, config.privateKeyPassword);
    });

    test('equality includes every field', () {
      expect(
        config,
        const ClientCertificateConfig(
          label: 'Hermes proxy',
          certificatePemPath: '/data/app/client-certs/a/certificate.pem',
          privateKeyPemPath: '/data/app/client-certs/a/private-key.pem',
          privateKeyPassword: 'secret',
        ),
      );
      expect(config, isNot(config.copyWith(label: 'Other')));
      expect(config, isNot(config.copyWith(privateKeyPassword: 'other')));
      expect(
        config,
        isNot(config.copyWith(certificatePemPath: '/other/certificate.pem')),
      );
    });
  });

  test('SavedConnection persists the client certificate in its map', () {
    final connection = SavedConnection(
      id: 'conn-1',
      label: 'mTLS proxy',
      host: 'hermes.example.com',
      port: 443,
      apiKey: 'key',
      useHttps: true,
      clientCertificate: config,
    );

    final restored = SavedConnection.fromMap(connection.toMap());

    expect(restored.clientCertificate, config);
    expect(
      connection.toMap()['client_certificate'],
      isA<Map<String, dynamic>>(),
    );
  });

  test('SavedConnection.copyWith can clear the client certificate', () {
    final connection = SavedConnection(
      id: 'conn-1',
      label: 'mTLS proxy',
      host: 'hermes.example.com',
      port: 443,
      apiKey: 'key',
      useHttps: true,
      clientCertificate: config,
    );

    expect(connection.copyWith(label: 'Renamed').clientCertificate, config);
    expect(
      connection.copyWith(clearClientCertificate: true).clientCertificate,
      isNull,
    );
  });
}
