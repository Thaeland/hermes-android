import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/client_certificate.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tls_client_factory.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingTlsClientFactory extends TlsClientFactory {
  _RecordingTlsClientFactory({this.restClient});

  final http.Client? restClient;
  ClientCertificateConfig? restConfig;
  ClientCertificateConfig? httpConfig;
  int restCalls = 0;
  int httpCalls = 0;

  @override
  http.Client createRestClient(ClientCertificateConfig? config) {
    restConfig = config;
    restCalls++;
    return restClient ?? super.createRestClient(config);
  }

  @override
  HttpClient createHttpClient(ClientCertificateConfig? config) {
    httpConfig = config;
    httpCalls++;
    return super.createHttpClient(config);
  }
}

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = <String, String>{};
  final Map<String, String> _cache = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
    _cache.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    if (value == null) {
      _cache.remove(key);
    } else {
      _cache[key] = value;
    }
    return value;
  }

  @override
  String? readCached(String key) => _cache[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  const certificate = ClientCertificateConfig(
    label: 'fixture',
    certificatePemPath: 'test/fixtures/client-cert.pem',
    privateKeyPemPath: 'test/fixtures/client-key.pem',
  );

  test(
    'DashboardClient builds its REST transport with the certificate',
    () async {
      final factory = _RecordingTlsClientFactory(
        restClient: MockClient((request) async {
          expect(request.url.path, '/api/model/info');
          return http.Response(jsonEncode(<String, dynamic>{}), 200);
        }),
      );
      final dashboard = DashboardClient(
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        proxied: true,
        clientCertificate: certificate,
        tlsClientFactory: factory,
      );
      addTearDown(dashboard.close);

      await dashboard.getModelInfo();

      expect(factory.restCalls, 1);
      expect(factory.restConfig, certificate);
    },
  );

  test('ApiClient uses the certificate instead of silently ignoring it', () {
    const broken = ClientCertificateConfig(
      label: 'broken',
      certificatePemPath: 'test/fixtures/client-cert.pem',
      privateKeyPemPath: 'test/fixtures/missing-key.pem',
    );

    expect(
      () => ApiClient(
        baseUrl: 'https://hermes.example.com',
        apiKey: 'key',
        clientCertificate: broken,
      ),
      throwsA(isA<TlsClientConfigurationException>()),
    );
  });

  test(
    'WsClient passes the certificate to its WebSocket HTTP client',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final savedHttpOverrides = HttpOverrides.current;
      // The binding replaces freshly constructed HttpClients with a mock;
      // clear the override so this real loopback handshake can proceed.
      HttpOverrides.global = null;
      try {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final subscriptions = <StreamSubscription<dynamic>>[];
        subscriptions.add(
          server.transform(WebSocketTransformer()).listen((socket) {
            sockets.add(socket);
          }),
        );
        addTearDown(() async {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
        });

        final factory = _RecordingTlsClientFactory();
        final client = WsClient(
          'http://127.0.0.1:${server.port}',
          clientCertificate: certificate,
          tlsClientFactory: factory,
          heartbeatInterval: Duration.zero,
          heartbeatDeadline: Duration.zero,
        );
        addTearDown(client.close);

        await client.connect().timeout(const Duration(seconds: 5));

        expect(factory.httpCalls, 1);
        expect(factory.httpConfig, certificate);
        expect(factory.restCalls, 0);
        expect(client.isConnected, isTrue);
      } finally {
        HttpOverrides.global = savedHttpOverrides;
      }
    },
  );

  test(
    'WsClient without a certificate keeps the platform default handshake',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final savedHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final subscription = server.transform(WebSocketTransformer()).listen((
          socket,
        ) {
          sockets.add(socket);
        });
        addTearDown(() async {
          await subscription.cancel();
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
        });

        final factory = _RecordingTlsClientFactory();
        final client = WsClient(
          'http://127.0.0.1:${server.port}',
          tlsClientFactory: factory,
          heartbeatInterval: Duration.zero,
          heartbeatDeadline: Duration.zero,
        );
        addTearDown(client.close);

        await client.connect().timeout(const Duration(seconds: 5));

        expect(client.isConnected, isTrue);
        // No custom client: the shared SDK HTTP client runs the handshake.
        expect(factory.httpCalls, 0);
        expect(factory.restCalls, 0);
      } finally {
        HttpOverrides.global = savedHttpOverrides;
      }
    },
  );

  test('ConnectionManager persists and reloads the certificate', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final credentials = _MemoryCredentialStore();
    final manager = await ConnectionManager.create(
      prefs,
      credentialStore: credentials,
    );

    await manager.saveConnection(
      'mTLS',
      'https://hermes.example.com',
      443,
      'key',
      clientCertificate: certificate,
    );

    final saved = manager.getConnections().single;
    expect(saved.clientCertificate, certificate);

    final reloaded = await ConnectionManager.create(
      prefs,
      credentialStore: credentials,
    );
    expect(reloaded.getConnections().single.clientCertificate, certificate);

    await manager.updateConnection(
      saved.id,
      saved.label,
      saved.host,
      saved.port,
      saved.apiKey,
      clearClientCertificate: true,
    );
    expect(manager.getConnections().single.clientCertificate, isNull);
  });
}
