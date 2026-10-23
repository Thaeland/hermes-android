import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/normal_gateway_application_session.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Gateway gateway;
  HttpOverrides? overrides;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    gateway = _Gateway();
    await gateway.start();
  });
  tearDown(() async {
    await gateway.close();
    HttpOverrides.global = overrides;
  });

  test(
    'production ingress delivers tokens once, resumes continued tools/deltas without resending',
    () async {
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final session = controller.normalSessionFor(gateway.connection);
      await session.ready;
      final chat = session.chatFor(
        'local',
        storedSessionId: 'stored',
        title: 'Wire chat',
      );
      chat.observeHistory([
        {'id': 10, 'role': 'assistant', 'content': 'Before'},
      ]);
      final flight = chat.submitPrepared(
        reservation: chat.reserve()!,
        text: 'Run',
        localContent: 'Run',
      );
      flight.ignore();
      await gateway.submitted.future;
      gateway.event('message.delta', {'text': 'Exactly once. '});
      await _until(
        () => chat.snapshot.displayRows.last['content'] == 'Exactly once. ',
      );
      await gateway.socket!.close();
      await flight;
      expect(controller.hasActiveTurn, isTrue);
      final resumed = gateway.nextResume = Completer<void>();
      chat.requestRecovery();
      await resumed.future;
      gateway.event('message.delta', {'text': 'After reconnect.'});
      gateway.event('tool.start', {
        'tool': 'read_file',
        'tool_id': 'tool-after',
      });
      await _until(() => chat.snapshot.tools.isNotEmpty);
      expect(
        chat.snapshot.displayRows.last['content'],
        'Exactly once. After reconnect.',
      );
      expect(
        gateway.requests.where((row) => row['method'] == 'prompt.submit'),
        hasLength(1),
      );
      expect(
        gateway.requests.where((row) => row['method'] == 'session.create'),
        isEmpty,
      );
      gateway.event('turn.end', {
        'status': 'failed',
        'error': 'Retained failure',
      });
      await _until(() => !controller.hasActiveTurn);
      expect(chat.phase, NormalGatewayTurnPhase.failed);
      expect(chat.snapshot.error, 'Retained failure');
    },
  );

  test(
    'emitted stale-runtime RPC error cannot automatically retry prompt.submit',
    () async {
      gateway.rejectSubmit = true;
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final session = controller.normalSessionFor(gateway.connection);
      await session.ready;
      final chat = session.chatFor(
        'local',
        storedSessionId: 'stored',
        title: 'Wire chat',
      );
      chat.observeHistory([]);
      await chat.submitPrepared(
        reservation: chat.reserve()!,
        text: 'Once',
        localContent: 'Once',
      );
      expect(chat.snapshot.wireEmitted, isTrue);
      expect(chat.phase, NormalGatewayTurnPhase.reconciling);
      expect(
        gateway.requests.where((row) => row['method'] == 'prompt.submit'),
        hasLength(1),
      );
      expect(
        gateway.requests.where((row) => row['method'] == 'session.create'),
        isEmpty,
      );
    },
  );

  test(
    'resume-only missing durable id never creates, even during recovery',
    () async {
      gateway.rejectResume = true;
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final session = controller.normalSessionFor(gateway.connection);
      await session.ready;
      await expectLater(
        session.client!.resumeSubmittedSession(
          localSessionId: 'local',
          storedSessionId: 'missing',
        ),
        throwsA(isA<JsonRpcError>()),
      );
      expect(
        gateway.requests.where((row) => row['method'] == 'session.create'),
        isEmpty,
      );
      expect(
        gateway.requests.where((row) => row['method'] == 'prompt.submit'),
        isEmpty,
      );
    },
  );

  test(
    'absent-route approval remains socket owned; reused wire id cannot approve new socket request',
    () async {
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final session = controller.normalSessionFor(gateway.connection);
      await session.ready;
      final chat = session.chatFor(
        'local',
        storedSessionId: 'stored',
        title: 'Wire chat',
      );
      await session.client!.ensureSession('local');
      gateway.approval();
      await _until(() => chat.snapshot.pendingInput.isNotEmpty);
      final oldId =
          chat.snapshot.pendingInput.single.data['server_request_id'] as String;
      expect(
        session.ownsApprovalRequest(sessionId: 'stored', requestId: oldId),
        isTrue,
      );
      // No route is subscribed, so nothing may reject the retained request.
      expect(gateway.responses, isEmpty);
      await gateway.socket!.close();
      await _until(() => chat.snapshot.pendingInput.isEmpty);
      await session.client!.resumeSubmittedSession(
        localSessionId: 'local',
        storedSessionId: 'stored',
      );
      gateway.approval();
      await _until(() => chat.snapshot.pendingInput.isNotEmpty);
      final newId =
          chat.snapshot.pendingInput.single.data['server_request_id'] as String;
      expect(newId, isNot(oldId));
      expect(
        await session.tryRespondToApproval(
          sessionId: 'stored',
          requestId: oldId,
          choice: 'approve',
        ),
        isFalse,
      );
      expect(
        await session.tryRespondToApproval(
          sessionId: 'stored',
          requestId: newId,
          choice: 'approve',
        ),
        isTrue,
      );
      await _until(() => gateway.responses.isNotEmpty);
      expect(gateway.responses.single['id'], 'approval-reused');
      expect(gateway.responses.single['result'], {'choice': 'approve'});
      // Reusing a wire id AFTER settlement on the SAME socket is a new
      // authority too; a saved notification action must not answer it.
      gateway.approval();
      await _until(() => chat.snapshot.pendingInput.isNotEmpty);
      final thirdId =
          chat.snapshot.pendingInput.single.data['server_request_id'] as String;
      expect(thirdId, isNot(newId));
      expect(
        await session.tryRespondToApproval(
          sessionId: 'stored',
          requestId: newId,
          choice: 'approve',
        ),
        isFalse,
      );
      expect(
        await session.tryRespondToApproval(
          sessionId: 'stored',
          requestId: thirdId,
          choice: 'reject',
        ),
        isTrue,
      );
      await _until(() => gateway.responses.length == 2);
    },
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Wire fixture condition did not arrive');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

class _Gateway {
  late HttpServer server;
  WebSocket? socket;
  String runtime = '';
  final sockets = <WebSocket>[];
  final requests = <Map<String, dynamic>>[];
  final responses = <Map<String, dynamic>>[];
  final submitted = Completer<void>();
  Completer<void>? nextResume;
  bool rejectSubmit = false;
  bool rejectResume = false;
  SavedConnection get connection => SavedConnection(
    id: 'real-wire',
    label: 'Wire fixture',
    host: '127.0.0.1',
    port: server.port,
    apiKey: 'fixture',
    dashboardPortOverride: server.port,
    dashboardProxied: true,
  );

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/api/auth/ws-ticket') {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ticket":"fixture-ticket"}');
        await request.response.close();
      } else if (request.uri.path.endsWith('/messages')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"data":[{"id":10,"role":"assistant","content":"Before"}]}',
        );
        await request.response.close();
      } else if (request.uri.path == '/api/ws') {
        final ws = await WebSocketTransformer.upgrade(request);
        socket = ws;
        sockets.add(ws);
        runtime = 'runtime-${sockets.length}';
        ws.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'server_requests': true},
            },
          }),
        );
        ws.listen((raw) {
          final frame = Map<String, dynamic>.from(
            jsonDecode(raw as String) as Map,
          );
          if (frame['method'] == null) {
            responses.add(frame);
            return;
          }
          requests.add(frame);
          final method = frame['method'];
          final rejected =
              method == 'prompt.submit' && rejectSubmit ||
              method == 'session.resume' && rejectResume;
          try {
            ws.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                if (rejected)
                  'error': {
                    'code': method == 'prompt.submit' ? 4001 : 4007,
                    'message': 'session not found',
                  }
                else
                  'result': method == 'session.resume'
                      ? {'session_id': runtime, 'running': true}
                      : {'ok': true},
              }),
            );
          } on StateError {
            // An already accepted request may reach the fixture while the
            // test closes the owner; a closed peer cannot receive the reply.
          }
          if (method == 'session.resume') {
            if (nextResume != null && !nextResume!.isCompleted) {
              nextResume!.complete();
            }
          }
          if (method == 'prompt.submit' && !submitted.isCompleted) {
            submitted.complete();
          }
        }, onDone: () {});
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });
  }

  void event(String type, Map<String, dynamic> payload) => socket!.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': type, 'session_id': runtime, 'payload': payload},
    }),
  );
  void approval() => socket!.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 'approval-reused',
      'method': 'approval',
      'params': {
        'session_id': runtime,
        'command': 'test',
        'description': 'Fixture action',
      },
    }),
  );
  Future<void> close() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await server.close(force: true);
  }
}
