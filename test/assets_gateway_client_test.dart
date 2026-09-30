import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/assets_gateway_client.dart';

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
  group('AssetsGatewayClient', () {
    test('status parses the availability verdict', () async {
      final rpc = _RecordingRpc([
        _ok({'available': true, 'attachments_present': true}),
      ]);
      final client = AssetsGatewayClient(rpc.call);

      final status = await client.status();

      expect(rpc.calls.single.method, 'assets.status');
      expect(status.available, isTrue);
    });

    test('unknown method converts to AssetsUnsupportedException', () async {
      final rpc = _RecordingRpc([
        _error(-32601, 'unknown method: assets.status'),
      ]);
      final client = AssetsGatewayClient(rpc.call);

      await expectLater(
        client.status(),
        throwsA(isA<AssetsUnsupportedException>()),
      );
    });
  });
}
