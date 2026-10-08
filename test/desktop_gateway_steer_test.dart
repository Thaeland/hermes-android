import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';

import 'chat_steer_test.dart' show SteerGatewayFixture;

void main() {
  group('DesktopGatewayClient.steerPrompt', () {
    test('maps queued to true and rejected to false', () async {
      final gateway = await SteerGatewayFixture.start(steerStatus: 'queued');
      addTearDown(gateway.stop);
      final client = DesktopGatewayClient.fromConnection(
        SavedConnection(
          id: 'steer-test',
          label: 'Steer fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      addTearDown(client.close);
      await client.ensureSession('mobile-1');

      expect(
        await client.steerPrompt(sessionId: 'mobile-1', text: 'go'),
        isTrue,
      );

      gateway.steerStatus = 'rejected';
      expect(
        await client.steerPrompt(sessionId: 'mobile-1', text: 'go'),
        isFalse,
      );

      // Unknown mobile session never reaches the socket.
      expect(
        await client.steerPrompt(sessionId: 'unmapped', text: 'go'),
        isFalse,
      );
    });
  });
}
