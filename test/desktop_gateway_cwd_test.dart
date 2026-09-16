// Regression for the retry/race gap found in PR #102 review: the Project
// cwd must survive a failed preflight. Only ensureSession used to carry it,
// and its exception is deliberately swallowed — so a first send after a
// transient failure could create the gateway session WITHOUT cwd and
// silently lose Project membership. The client now remembers the desired
// cwd per mobile session, and every creation-capable call resolves it.
//
// These tests drive a real local WS server (same shape as the
// connection_manager wire tests) and assert the exact session.create
// frames the client puts on the wire.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';

class _FakeGateway {
  _FakeGateway(this._server, this.createFrames, this.failFirstCreate);

  final HttpServer _server;
  final List<Map<String, dynamic>> createFrames;
  final bool failFirstCreate;

  static Future<_FakeGateway> start({required bool failFirstCreate}) async {
    final createFrames = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var createdOnce = false;
    server.listen((httpReq) async {
      // Dashboard auth surface (token-scrape fallback + ticket mint).
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
          ..headers.set(
            'set-cookie',
            'hermes_session_at=TOK123; Path=/',
          )
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
        // gateway.ready must arrive before the client proceeds.
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
              // Nothing exists yet — force the create path.
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': {'code': 4007, 'message': 'session not found'},
                }),
              );
            case 'session.create':
              final params =
                  Map<String, dynamic>.from(request['params'] as Map);
              createFrames.add(params);
              if (failFirstCreate && !createdOnce) {
                createdOnce = true;
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': id,
                    'error': {
                      'code': 5000,
                      'message': 'transient: gateway busy',
                    },
                  }),
                );
              } else {
                createdOnce = true;
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': id,
                    'result': {
                      'session_id': 'gw-runtime-1',
                      'stored_session_id': 'gw-stored-1',
                    },
                  }),
                );
              }
            default:
              // prompt.submit and anything else: fail fast so the caller
              // returns; the assertion lives in the captured create frame.
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': {'code': 1, 'message': 'not needed for this test'},
                }),
              );
          }
        });
        return;
      }
      httpReq.response.statusCode = 404;
      await httpReq.response.close();
    });
    return _FakeGateway(server, createFrames, failFirstCreate);
  }

  Future<void> stop() => _server.close(force: true);
}

SavedConnection _connection(int port) => SavedConnection(
  id: 'conn-cwd',
  label: 'Local fake',
  // Distinct from the gateway URL host: normalizedGatewayBaseUrl treats a
  // same-host override as non-distinct and falls back to the dashboard
  // port, which would bypass the fake server entirely.
  host: 'localhost',
  port: port,
  apiKey: 'k',
  useHttps: false,
  desktopGatewayUrl: 'http://127.0.0.1:$port',
  dashboardUsername: 'u',
  dashboardPassword: 'p',
);

void main() {
  test('remembered cwd reaches session.create after a failed preflight', () async {
    final gateway = await _FakeGateway.start(failFirstCreate: true);
    final client = DesktopGatewayClient.fromConnection(
      _connection(gateway._server.port),
    );
    addTearDown(() async {
      client.close();
      await gateway.stop();
    });

    // 1. Preflight with the project cwd fails transiently (swallowed by
    //    ChatScreen in production; thrown here).
    await expectLater(
      client.ensureSession(
        'mob-1',
        workingDirectory: '/srv/projects/app',
      ),
      throwsA(anything),
    );
    expect(gateway.createFrames, hasLength(1));

    // 2. The first send retries creation. It passes NO explicit cwd —
    //    the client must still create the session with the remembered one.
    await expectLater(
      client.submitPrompt(
        sessionId: 'mob-1',
        text: 'hello',
        onEvent: (_) {},
      ),
      throwsA(anything),
    );
    expect(gateway.createFrames, hasLength(2));
    expect(gateway.createFrames.last, {'cwd': '/srv/projects/app'});
    expect(gateway.createFrames.last, isNot(contains('session_id')));
  });

  test('explicit cwd on a later call overrides the remembered one', () async {
    final gateway = await _FakeGateway.start(failFirstCreate: true);
    final client = DesktopGatewayClient.fromConnection(
      _connection(gateway._server.port),
    );
    addTearDown(() async {
      client.close();
      await gateway.stop();
    });

    // First attempt fails; the intent /srv/first is remembered.
    await expectLater(
      client.ensureSession('mob-2', workingDirectory: '/srv/first'),
      throwsA(anything),
    );
    // A later explicit cwd wins over the remembered one.
    await client.ensureSession('mob-2', workingDirectory: '/srv/second');
    expect(gateway.createFrames.first, {'cwd': '/srv/first'});
    expect(gateway.createFrames.last, {'cwd': '/srv/second'});
  });
}
