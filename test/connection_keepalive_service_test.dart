// Background keep-alive contract: the Dart side must drive the native
// foreground service exactly once per background/foreground cycle, must
// treat a refused or missing native start as a silent no-op (the
// transport's reconnect-on-resume loop is the fallback), and the live
// client counter that gates the service must track open clients exactly.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/connection_keepalive_service.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockChannel(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ConnectionKeepAliveService.channel, handler);
  }

  tearDown(() => mockChannel(null));

  test('start/stop drive the native service once each and are idempotent',
      () async {
    final calls = <String>[];
    mockChannel((call) async {
      calls.add(call.method);
      return true;
    });

    final service = ConnectionKeepAliveService();
    await service.start();
    await service.start();
    expect(service.isActive, isTrue);
    await service.stop();
    await service.stop();
    expect(service.isActive, isFalse);
    expect(calls, ['start', 'stop']);
  });

  test('a refused native start leaves the service inactive', () async {
    final calls = <String>[];
    mockChannel((call) async {
      calls.add(call.method);
      return false;
    });

    final service = ConnectionKeepAliveService();
    await service.start();
    expect(service.isActive, isFalse);
    // Not active, so stop must not spam the native side.
    await service.stop();
    expect(calls, ['start']);
  });

  test('missing native plugin (non-Android host) is a silent no-op', () async {
    // No mock handler: invokeMethod throws MissingPluginException.
    final service = ConnectionKeepAliveService();
    await service.start();
    expect(service.isActive, isFalse);
    await service.stop();
  });

  test('liveConnectionCount tracks open DesktopGatewayClients', () {
    final before = DesktopGatewayClient.liveConnectionCount;
    final client = DesktopGatewayClient.fromConnection(
      SavedConnection(
        id: 'conn-counter',
        label: 'Counter fixture',
        host: 'localhost',
        port: 1,
        apiKey: 'fixture-key',
        useHttps: false,
      ),
    );
    expect(DesktopGatewayClient.liveConnectionCount, before + 1);
    client.close();
    expect(DesktopGatewayClient.liveConnectionCount, before);
    // Double close must not decrement twice.
    client.close();
    expect(DesktopGatewayClient.liveConnectionCount, before);
  });
}
