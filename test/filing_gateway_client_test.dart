import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/filing_gateway_client.dart';

/// Records the JSON-RPC calls a test makes and replays canned envelopes.
class _RecordingRpc {
  final List<({String method, Map<String, dynamic> params})> calls = [];
  final List<Map<String, dynamic>> responses;

  _RecordingRpc(this.responses);

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method: method, params: params));
    if (responses.isEmpty) {
      throw StateError('no canned response for $method');
    }
    return responses.removeAt(0);
  }
}

Map<String, dynamic> _ok(Map<String, dynamic> result) => {
  'jsonrpc': '2.0',
  'id': 1,
  'result': result,
};

Map<String, dynamic> _error(int code, String message) => {
  'jsonrpc': '2.0',
  'id': 1,
  'error': {'code': code, 'message': message},
};

void main() {
  group('FilingGatewayClient', () {
    test('status parses the availability verdict', () async {
      final rpc = _RecordingRpc([
        _ok({'available': true, 'hook_installed': true}),
      ]);
      final client = FilingGatewayClient(rpc.call);

      final status = await client.status();

      expect(rpc.calls.single.method, 'filing.status');
      expect(status.available, isTrue);
    });

    test('unknown method converts to FilingUnsupportedException', () async {
      final rpc = _RecordingRpc([
        _error(-32601, 'unknown method: filing.status'),
      ]);
      final client = FilingGatewayClient(rpc.call);

      await expectLater(
        client.status(),
        throwsA(isA<FilingUnsupportedException>()),
      );
    });

    test('suggest parses rows and skips malformed ones', () async {
      final rpc = _RecordingRpc([
        _ok({
          'suggestions': [
            {
              'session_id': 's1',
              'title': 'Chat',
              'cwd': '/home/dev/app',
              'project_id': 'p1',
              'project_name': 'App',
              'reason': 'cwd_match',
              'confidence': 0.9,
            },
            {'title': 'missing ids'},
          ],
        }),
      ]);
      final client = FilingGatewayClient(rpc.call);

      final suggestions = await client.suggest();

      expect(suggestions, hasLength(1));
      expect(suggestions.single.sessionId, 's1');
      expect(suggestions.single.cwd, '/home/dev/app');
      expect(suggestions.single.isUserRule, isFalse);
    });

    test('apply sends path, project, and source', () async {
      final rpc = _RecordingRpc([_ok({'note': 'filed'})]);
      final client = FilingGatewayClient(rpc.call);

      final note = await client.apply(path: '/p', project: 'App');

      expect(note, 'filed');
      expect(rpc.calls.single.method, 'filing.apply');
      expect(rpc.calls.single.params['path'], '/p');
      expect(rpc.calls.single.params['project'], 'App');
      expect(rpc.calls.single.params['source'], 'android:accept');
    });

    test('reject omits a blank project', () async {
      final rpc = _RecordingRpc([_ok({})]);
      final client = FilingGatewayClient(rpc.call);

      final note = await client.reject(path: '/p', project: '  ');

      expect(note, 'recorded');
      expect(rpc.calls.single.params.containsKey('project'), isFalse);
    });
  });
}
