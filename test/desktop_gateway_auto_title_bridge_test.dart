// Companion to chat_auto_title_test.dart: proves the DesktopGatewayClient
// async-event bridge relays a pushed `session.title` (carrying the STORED
// session key, as tui_gateway/prompt_turn.py emits it) to the owning
// mobile session. Lives in its own file because TestWidgetsFlutterBinding
// (pulled in by testWidgets) mocks all HTTP to 400 — this needs a real
// local WS server, same harness shape as desktop_gateway_cwd_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';

const _fixtureKey = 'fixture-key';

void main() {
  test('async bridge relays session.title to the owning mobile session', () async {
    // The async bridge only relays whitelisted types; without the
    // session.title entry a title pushed after the terminal event (or on
    // reconnect) never reaches the open chat.
    final gateway = await _TitleFakeGateway.start();
    addTearDown(gateway.stop);
    final client = DesktopGatewayClient.fromConnection(
      SavedConnection(
        id: 'conn-title',
        label: 'Local fake',
        // Distinct host alias: a same-host override falls back to the
        // dashboard port and bypasses the fake entirely.
        host: 'localhost',
        port: gateway.port,
        apiKey: _fixtureKey,
        useHttps: false,
        desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
        dashboardUsername: 'u',
        dashboardPassword: 'p',
      ),
    );
    addTearDown(client.close);

    final received = <StreamEvent>[];
    client.setAsyncEventListener((mobileSessionId, event) {
      if (mobileSessionId == 'mob-title') received.add(event);
    });
    await client.ensureSession('mob-title');
    gateway.pushTitle('stored-key-1', 'Renamed by the gateway');
    await _waitFor(() => received.isNotEmpty);

    expect(received, hasLength(1));
    expect(received.single.type, 'session.title');
    expect(received.single.data['title'], 'Renamed by the gateway');
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _TitleFakeGateway {
  _TitleFakeGateway(this._server, this._socketReady);

  final HttpServer _server;
  final Completer<WebSocket> _socketReady;
  int get port => _server.port;

  static Future<_TitleFakeGateway> start() async {
    final socketReady = Completer<WebSocket>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((httpReq) async {
      if (httpReq.method == 'GET' && httpReq.uri.path == '/') {
        httpReq.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('<html>window.__HERMES_SESSION_TOKEN__="TESTTOKEN";</html>');
        await httpReq.response.close();
        return;
      }
      if (httpReq.method == 'POST' &&
          httpReq.uri.path == '/auth/password-login') {
        httpReq.response
          ..statusCode = 200
          ..headers.set('set-cookie', 'hermes_session_at=TOK123; Path=/')
          ..write('{"ok":true}');
        await httpReq.response.close();
        return;
      }
      if (httpReq.method == 'POST' &&
          httpReq.uri.path == '/api/auth/ws-ticket') {
        httpReq.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"ticket":"TICKET-1"}');
        await httpReq.response.close();
        return;
      }
      if (httpReq.uri.path == '/api/ws') {
        final socket = await WebSocketTransformer.upgrade(httpReq);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}},
          }),
        );
        socket.listen((raw) {
          final request = jsonDecode(raw as String) as Map<String, dynamic>;
          final id = request['id'];
          switch (request['method']) {
            case 'session.resume':
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': {'code': 4007, 'message': 'session not found'},
                }),
              );
            case 'session.create':
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': {
                    'session_id': 'gw-runtime-1',
                    'stored_session_id': 'stored-key-1',
                  },
                }),
              );
            default:
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': {'code': 1, 'message': 'not needed for this test'},
                }),
              );
          }
        });
        if (!socketReady.isCompleted) socketReady.complete(socket);
        return;
      }
      httpReq.response.statusCode = 404;
      await httpReq.response.close();
    });
    return _TitleFakeGateway(server, socketReady);
  }

  /// Push a server-side auto-title for the stored session key, exactly as
  /// tui_gateway/prompt_turn.py emits it.
  void pushTitle(String storedSessionId, String title) {
    _socketReady.future.then((ws) {
      ws.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'session.title',
            'payload': {'session_id': storedSessionId, 'title': title},
          },
        }),
      );
    });
  }

  Future<void> stop() => _server.close(force: true);
}
