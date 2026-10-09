import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';

import 'chat_steer_test.dart' show SteerGatewayFixture;

void main() {
  group('DesktopGatewayClient.steerPrompt', () {
    test('maps queued to accepted and rejected to rejected', () async {
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
        SteerOutcome.accepted,
      );

      gateway.steerStatus = 'rejected';
      expect(
        await client.steerPrompt(sessionId: 'mobile-1', text: 'go'),
        SteerOutcome.rejected,
      );

      // Unknown mobile session never reaches the socket.
      expect(
        await client.steerPrompt(sessionId: 'unmapped', text: 'go'),
        SteerOutcome.rejected,
      );
    });

    test('a gateway error response is an explicit rejection', () async {
      final gateway = await SteerGatewayFixture.start(errorCode: 4010);
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
        SteerOutcome.rejected,
      );
    });

    test('a coded gateway error is rejected even when its message reads Timeout',
        () async {
      // Classification must key on the JSON-RPC code, not message text:
      // a real gateway rejection whose message happens to say 'Timeout'
      // is still a definite, applied-nowhere refusal, not a lost ack.
      final gateway = await SteerGatewayFixture.start(
        errorCode: 4002,
        steerErrorMessage: 'Timeout',
      );
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
        SteerOutcome.rejected,
      );
    });

    test('a lost acknowledgement after write is uncertain, not rejected',
        () async {
      final gateway = await SteerGatewayFixture.start();
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

      // The fixture records the steer frame and kills the socket before
      // answering: the frame was definitely written, the ack never came.
      gateway.dropSteerAck = true;
      expect(
        await client.steerPrompt(sessionId: 'mobile-1', text: 'go'),
        SteerOutcome.uncertain,
      );
      expect(gateway.steerParamsList.single['text'], 'go');
    });
  });
}
