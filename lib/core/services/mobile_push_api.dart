import 'dart:convert';

import 'connection_manager.dart';

/// All requests use the existing dashboard login/cookie/proxy/token ladder.
/// Subscriber keys come exclusively from the native connector, never VAPID.
class MobilePushApi {
  MobilePushApi(this.client);
  final DashboardClient client;
  static const prefix = 'plugins/mobile-push';

  Map<String, String> _query([Map<String, String> parameters = const {}]) => {
    ...parameters,
    if (client.gatewayProfile != null) 'profile': client.gatewayProfile!,
  };

  Future<Map<String, dynamic>> capabilities() async {
    final result = await client.apiGet(
      '$prefix/capabilities',
      queryParameters: _query(),
    );
    final key = result['vapid_public_key'];
    if (result['schema'] != 1 ||
        result['enabled'] != true ||
        result['transports'] is! List ||
        !(result['transports'] as List).contains('webpush') ||
        key is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{87}$').hasMatch(key)) {
      throw const FormatException('Mobile push is unavailable on this server.');
    }
    final bytes = base64Url.decode(base64Url.normalize(key));
    if (bytes.length != 65 || bytes.first != 4) {
      throw const FormatException('Invalid server VAPID public key.');
    }
    return result;
  }

  Future<Map<String, dynamic>> register(
    Map<String, dynamic> state,
  ) => client.apiPut(
    '$prefix/registrations/${Uri.encodeComponent(state['installation'] as String)}',
    queryParameters: _query(),
    body: {
      'endpoint': state['endpoint'],
      'keys': state['keys'],
      'registration_nonce': state['nonce'],
      'event_kinds': const [
        'turn_done',
        'turn_error',
        'input',
        'input_resolved',
      ],
      'session_ids': state['sessions'],
    },
  );

  Future<Map<String, dynamic>> confirm(
    String installation,
    int generation,
    String challenge,
  ) => client.apiPost(
    '$prefix/registrations/${Uri.encodeComponent(installation)}/confirm',
    queryParameters: _query(),
    body: {'generation': generation, 'challenge': challenge},
  );
  Future<void> revoke(String installation) => client.apiDelete(
    '$prefix/registrations/${Uri.encodeComponent(installation)}',
    queryParameters: _query(),
  );
  Future<Map<String, dynamic>> events(String cursor) => client.apiGet(
    '$prefix/events',
    queryParameters: _query({'after': cursor, 'limit': '100'}),
  );
}
