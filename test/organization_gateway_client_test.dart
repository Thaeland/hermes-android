import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/organization_gateway_client.dart';

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
  group('OrganizationGatewayClient', () {
    test('pin sends session_ids and parses the batch result', () async {
      final rpc = _RecordingRpc([
        _ok({
          'batch_id': 'b1',
          'applied': ['s1', 's2'],
          'failed': [],
        }),
      ]);
      final client = OrganizationGatewayClient(rpc.call);

      final result = await client.pin(['s1', 's2'], pinned: true);

      expect(rpc.calls.single.method, 'organization.pin');
      expect(rpc.calls.single.params['session_ids'], ['s1', 's2']);
      expect(rpc.calls.single.params['pinned'], isTrue);
      expect(result.batchId, 'b1');
      expect(result.applied, ['s1', 's2']);
      expect(result.appliedCount, 2);
      expect(result.partial, isFalse);
    });

    test('a partial batch keeps its undo handle and reports failures', () async {
      final rpc = _RecordingRpc([
        _ok({
          'batch_id': 'b2',
          'applied': ['s1'],
          'failed': [
            {'session_id': 's2', 'error': 'gone'},
          ],
        }),
      ]);
      final client = OrganizationGatewayClient(rpc.call);

      final result = await client.archive(['s1', 's2'], archived: true);

      expect(result.partial, isTrue);
      expect(result.failed.single['session_id'], 's2');
      expect(result.appliedCount, 1);
    });

    test('applied as a plain count still yields appliedCount', () async {
      final rpc = _RecordingRpc([
        _ok({
          'batch_id': 'b3',
          'applied': 3,
          'failed': [],
        }),
      ]);
      final client = OrganizationGatewayClient(rpc.call);

      final result = await client.pin(['s1', 's2', 's3'], pinned: true);

      expect(result.applied, isEmpty);
      expect(result.appliedCount, 3);
    });

    test('unknown method converts to OrganizationUnsupportedException', () async {
      final rpc = _RecordingRpc([
        _error(-32601, 'unknown method: organization.pin'),
      ]);
      final client = OrganizationGatewayClient(rpc.call);

      await expectLater(
        client.pin(['s1'], pinned: true),
        throwsA(isA<OrganizationUnsupportedException>()),
      );
    });

    test('undo trims and omits a blank batch id', () async {
      final rpc = _RecordingRpc([
        _ok({'batch_id': 'b9', 'applied': [], 'failed': []}),
        _ok({'batch_id': 'b10', 'applied': [], 'failed': []}),
      ]);
      final client = OrganizationGatewayClient(rpc.call);

      await client.undo(batchId: '  b9  ');
      await client.undo(batchId: '   ');

      expect(rpc.calls.first.params['batch_id'], 'b9');
      expect(rpc.calls.last.params.containsKey('batch_id'), isFalse);
    });

    test('history parses rows and skips malformed ones', () async {
      final rpc = _RecordingRpc([
        _ok({
          'batches': [
            {
              'id': 'b1',
              'ts': 1.5,
              'action': 'pinned',
              'value': 1,
              'count': 2,
              'undone': false,
            },
            {'action': 'archived'},
          ],
        }),
      ]);
      final client = OrganizationGatewayClient(rpc.call);

      final entries = await client.history();

      expect(entries, hasLength(1));
      expect(entries.single.id, 'b1');
      expect(entries.single.label, 'Pinned');
    });
  });
}
