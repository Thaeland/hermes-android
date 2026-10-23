import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:hermes_android/core/widgets/mobile_push_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_push_service.dart';
import 'package:hermes_android/core/services/notification_prefs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemorySecrets implements CredentialStore {
  final values = <String, String>{};
  @override
  String? readCached(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Controlled native boundary; cryptographic/decrypted gates are separately
/// tested by the real Kotlin policy. HTTP below is an authenticated API fixture,
/// not evidence of a live server subscription or physical device delivery.
class Fixture {
  final native = <String, dynamic>{'enabled': false};
  final methods = <String>[];
  final requests = <http.Request>[];
  final MethodChannel channel = const MethodChannel(
    MobilePushService.channelName,
  );
  late final MobilePushService service;
  late final ConnectionManager manager;
  late final SavedConnection connection;
  int capsStatus = 200;
  bool permission = true;
  bool failRevoke = false;
  Future<http.Response> Function(http.Request)? onPut;
  Future<http.Response> Function(http.Request)? onConfirm;
  List<Map<String, dynamic>> feed = [];
  int eventPageSize = 100;
  final int expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  Map<String, dynamic> clone(Map<String, dynamic> source) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);
  Future<void> setup() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    manager = ConnectionManager(prefs, credentialStore: MemorySecrets());
    await manager.saveConnection(
      'Fixture',
      'https://fixture.invalid',
      443,
      'gateway-test-key',
      dashboardPrefix: '/dash',
      dashboardUsername: 'fixture-user',
      dashboardPassword: 'fixture-password',
    );
    connection = manager.getConnections().single;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
          switch (call.method) {
            case 'permission':
              return permission;
            case 'distributors':
              return ['test.distributor'];
            case 'snapshot':
              return clone(native);
            case 'preferences':
              native.addAll(args);
              return clone(native);
            case 'enable':
              native.addAll({
                ...args,
                'enabled': true,
                'active': false,
                'installation': 'fixture-installation',
                'nonce': 'fixture-nonce',
                'revision': 1,
                'generation': 0,
              });
              return clone(native);
            case 'generation':
              if (args['nonce'] != native['nonce'] ||
                  args['revision'] != native['revision'] ||
                  native['enabled'] != true) {
                throw PlatformException(code: 'stale');
              }
              native['generation'] = args['generation'];
              return clone(native);
            case 'activate':
              if (args['nonce'] != native['nonce'] ||
                  native['enabled'] != true) {
                throw PlatformException(code: 'stale');
              }
              native['active'] = true;
              native.remove('challenges');
              return clone(native);
            case 'disable':
              final revokes = native['revocations'] as List? ?? [];
              if (native['enabled'] == true) {
                revokes.add({
                  'connection': native['connection'],
                  'installation': native['installation'],
                  'binding': native['binding'],
                });
              }
              native.addAll({
                'enabled': false,
                'active': false,
                'nonce': '',
                'generation': 0,
                'revocations': revokes,
              });
              native.remove('challenges');
              native.remove('tap');
              return clone(native);
            case 'revoked':
              native['revocations'] = (native['revocations'] as List)
                  .where(
                    (e) => e['installation'] != args['revokedInstallation'],
                  )
                  .toList();
              return clone(native);
            case 'takeTap':
              return native.remove('tap');
            case 'retryDistributor':
              return clone(native);
            default:
              throw StateError(call.method);
          }
        });
    service = MobilePushService(
      supported: true,
      channel: channel,
      clientFactory: (c) => DashboardClient(
        host: c.host,
        port: c.dashboardPort,
        useHttps: c.useHttps,
        pathPrefix: c.dashboardPrefix!,
        username: c.dashboardUsername,
        password: c.dashboardPassword,
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/dash/auth/password-login') {
            expect(jsonDecode(request.body)['username'], 'fixture-user');
            return http.Response(
              '{}',
              200,
              headers: {
                'set-cookie': 'hermes_session_at=fixture-cookie; HttpOnly',
              },
            );
          }
          expect(request.url.host, 'fixture.invalid');
          expect(
            request.url.path.startsWith('/dash/api/plugins/mobile-push/'),
            isTrue,
          );
          expect(request.headers['Cookie'], 'hermes_session_at=fixture-cookie');
          expect(request.headers.containsKey('Authorization'), isFalse);
          if (request.url.path.endsWith('/capabilities')) {
            return http.Response(
              jsonEncode({
                'schema': 1,
                'enabled': true,
                'transports': ['webpush'],
                'vapid_public_key': base64Url
                    .encode([4, ...List<int>.filled(64, 1)])
                    .replaceAll('=', ''),
              }),
              capsStatus,
            );
          }
          if (request.method == 'PUT') {
            if (onPut != null) return onPut!(request);
            return pending();
          }
          if (request.url.path.endsWith('/confirm')) {
            if (onConfirm != null) return onConfirm!(request);
            return http.Response('{"status":"active"}', 200);
          }
          if (request.method == 'DELETE') {
            return http.Response('{}', failRevoke ? 503 : 200);
          }
          if (request.url.path.endsWith('/events')) {
            final after = int.parse(request.url.queryParameters['after']!);
            final page = feed.skip(after).take(eventPageSize).toList();
            final next = after + page.length;
            return http.Response(
              jsonEncode({
                'events': page,
                'next_cursor': next,
                'has_more': next < feed.length,
              }),
              200,
            );
          }
          throw StateError('Unexpected fixture request');
        }),
      ),
    );
  }

  http.Response pending() => http.Response(
    jsonEncode({
      'generation': 7,
      'status': 'pending',
      'registration_nonce': native['nonce'],
    }),
    200,
  );
  void seed({bool active = false}) {
    native.addAll({
      'enabled': true,
      'active': active,
      'connection': connection.id,
      'binding': MobilePushService.binding(connection),
      'installation': 'fixture-installation',
      'nonce': 'fixture-nonce',
      'revision': 1,
      'generation': active ? 7 : 0,
      'sessions': ['durable-session'],
      'endpoint': 'https://distributor.invalid/test',
      'keys': {'p256dh': 'test-fixture-only', 'auth': 'test-fixture-only'},
    });
  }

  void challenge({int generation = 7}) {
    native['challenges'] = [
      {
        'schema': 1,
        'kind': 'challenge',
        'event_id': 'challenge-event',
        'generation': generation,
        'registration_nonce': native['nonce'],
        'expires_at': expiry,
        'challenge': 'fixture-encrypted-proof',
      },
    ];
  }

  Map<String, dynamic> event(
    String id, {
    String session = 'durable-session',
    String kind = 'turn_done',
    int? expires,
  }) => {
    'cursor': 1,
    'event_id': id,
    'kind': kind,
    'session_id': session,
    'created_at': expiry - 3600,
    'expires_at': expires ?? expiry,
  };
  void tap(String id) {
    native['tap'] = {
      'event_id': id,
      'connection': connection.id,
      'installation': native['installation'],
      'nonce': native['nonce'],
      'revision': native['revision'],
      'generation': native['generation'],
      'expires_at': expiry,
    };
  }

  Future<void> changed() {
    final result = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          MobilePushService.channelName,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('changed'),
          ),
          (_) => result.complete(),
        );
    return result.future;
  }

  void close() {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Fixture f;
  setUp(() async {
    notificationPrefs.value = NotificationPrefs.defaults;
    f = Fixture();
    await f.setup();
  });
  tearDown(() {
    f.close();
  });
  test(
    'off by default; startup performs no permission, connector or network registration',
    () async {
      await f.service.initialize(f.manager);
      expect(f.service.enabled, isFalse);
      expect(f.requests, isEmpty);
      expect(f.methods, isNot(contains('permission')));
      expect(f.methods, isNot(contains('enable')));
    },
  );
  testWidgets(
    'settings requires explicit consent, durable IDs and enable before requesting permission',
    (tester) async {
      await tester.runAsync(() => f.service.initialize(f.manager));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MobilePushSettings(
                connection: f.connection,
                connectionManager: f.manager,
                service: f.service,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await f.service.initialize(f.manager);
        await f.service.distributors();
      });
      await tester.pumpAndSettle();
      expect(find.text('Android UnifiedPush (optional)'), findsOneWidget);
      expect(find.text('test.distributor'), findsOneWidget);
      final enable = find.widgetWithText(
        FilledButton,
        'Enable for selected sessions',
      );
      expect(tester.widget<FilledButton>(enable).onPressed, isNull);
      expect(f.methods, isNot(contains('permission')));
      await tester.enterText(find.byType(TextField), 'durable-session');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(enable).onPressed, isNotNull);
      await tester.ensureVisible(enable);
      await tester.tap(enable);
      await tester.pumpAndSettle();
      expect(f.methods, contains('permission'));
      expect(f.native['sessions'], ['durable-session']);
      expect(find.text('Disable and revoke'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'startup hydrates disabled notification preferences before native sync',
    () async {
      await f.manager.prefs.setString(
        NotificationPrefsStore.storageKey,
        jsonEncode(
          NotificationPrefs.defaults.copyWith(enabled: false).toJson(),
        ),
      );
      await f.service.initialize(f.manager);
      expect(f.native['master'], isFalse);
      expect(
        f.methods.where((method) => method == 'preferences'),
        hasLength(1),
      );
    },
  );
  test('empty allowlist fails before permission or HTTP', () async {
    await f.service.initialize(f.manager);
    await expectLater(
      f.service.enable(f.connection, 'test.distributor', []),
      throwsStateError,
    );
    expect(f.requests, isEmpty);
  });
  test(
    'missing plugin and forbidden principal are honest and never opt in',
    () async {
      await f.service.initialize(f.manager);
      f.capsStatus = 404;
      await expectLater(
        f.service.enable(f.connection, 'test.distributor', ['durable-session']),
        throwsA(isA<DashboardHttpException>()),
      );
      expect(f.service.error, contains('not installed'));
      f.capsStatus = 403;
      await expectLater(
        f.service.enable(f.connection, 'test.distributor', ['durable-session']),
        throwsA(isA<DashboardHttpException>()),
      );
      expect(f.service.error, contains('denied'));
      expect(f.methods, isNot(contains('enable')));
    },
  );
  test('permission denial never grants native consent', () async {
    await f.service.initialize(f.manager);
    f.permission = false;
    await expectLater(
      f.service.enable(f.connection, 'test.distributor', ['durable-session']),
      throwsStateError,
    );
    expect(f.methods, isNot(contains('enable')));
  });
  test(
    'explicit opt in binds one connection and only selected durable IDs',
    () async {
      await f.service.initialize(f.manager);
      await f.service.enable(f.connection, 'test.distributor', [
        'durable-session',
        'durable-session',
      ]);
      expect(f.native['sessions'], ['durable-session']);
      expect(f.native['connection'], f.connection.id);
      expect(f.service.active, isFalse);
      expect(f.service.status, contains('Pending distributor'));
    },
  );
  test(
    'challenge delivered during PUT is queued and confirmed after generation response',
    () async {
      f.seed();
      f.onPut = (request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['session_ids'], ['durable-session']);
        expect(body['keys'], f.native['keys']);
        expect(body.containsKey('vapid_public_key'), isFalse);
        f.challenge(); // native received and persisted BEFORE PUT completed
        return f.pending();
      };
      await f.service.initialize(f.manager);
      expect(f.service.active, isTrue);
      expect(
        f.methods.indexOf('generation'),
        lessThan(f.methods.indexOf('activate')),
      );
      final confirm = f.requests.singleWhere(
        (r) => r.url.path.endsWith('/confirm'),
      );
      expect(jsonDecode(confirm.body), {
        'generation': 7,
        'challenge': 'fixture-encrypted-proof',
      });
    },
  );
  test('old challenge cannot activate a new generation', () async {
    f.seed();
    f.challenge(generation: 6);
    await f.service.initialize(f.manager);
    expect(f.service.active, isFalse);
    expect(f.methods, isNot(contains('activate')));
  });
  test(
    'disable while PUT is in flight clears local authority before network revoke',
    () async {
      f.seed();
      final put = Completer<http.Response>();
      final started = Completer<void>();
      f.onPut = (_) {
        started.complete();
        return put.future;
      };
      final initialization = f.service.initialize(f.manager);
      await started.future;
      final disabled = f.service.disable();
      // Let the MethodChannel persist disable without completing the held PUT.
      await Future<void>.delayed(Duration.zero);
      expect(f.native['enabled'], isFalse);
      put.complete(
        http.Response(
          '{"generation":7,"status":"pending","registration_nonce":"fixture-nonce"}',
          200,
        ),
      );
      await initialization;
      await disabled;
      expect(f.methods, isNot(contains('generation')));
      expect(f.methods, isNot(contains('activate')));
    },
  );
  test(
    'renewal during confirmation makes late confirmation powerless',
    () async {
      f.seed();
      f.challenge();
      f.onConfirm = (_) async {
        f.native.addAll({
          'nonce': 'renewed-nonce',
          'revision': 2,
          'generation': 0,
          'active': false,
        });
        return http.Response('{"status":"active"}', 200);
      };
      await f.service.initialize(f.manager);
      expect(f.native['active'], isFalse);
      expect(f.methods, isNot(contains('activate')));
    },
  );
  test(
    'failed server revoke remains durable and is retried on next foreground refresh',
    () async {
      f.seed(active: true);
      await f.service.initialize(f.manager);
      f.failRevoke = true;
      await f.service.disable();
      expect(f.native['enabled'], isFalse);
      expect(f.service.pendingRevocations, 1);
      f.failRevoke = false;
      await f.service.refresh();
      expect(f.service.pendingRevocations, 0);
    },
  );
  test(
    'native changed callback reconciles all pages and routes only authorized live events',
    () async {
      f.seed(active: true);
      await f.service.initialize(f.manager);
      f.eventPageSize = 1;
      f.feed = [
        f.event('old', expires: 1),
        f.event('other', session: 'not-selected'),
        f.event('valid'),
      ];
      f.tap('valid');
      await f.changed();
      expect(f.service.events.map((e) => e['event_id']), ['valid']);
      final route = await f.service.takePendingNotificationRoute();
      expect(route?.sessionId, 'durable-session');
      expect(await f.service.isRouteCurrent(route!), isTrue);
      await f.service.disable();
      expect(await f.service.isRouteCurrent(route), isFalse);
    },
  );
  test(
    'notification master and kind preferences sync to native and reject stale taps',
    () async {
      f.seed(active: true);
      f.feed = [f.event('valid')];
      await f.service.initialize(f.manager);
      final prefs = NotificationPrefs.defaults.copyWith(
        kind: HermesNotificationKind.turnDone,
        kindValue: false,
      );
      notificationPrefs.value = prefs;
      await f.service.syncPreferences(prefs);
      expect(f.native['kinds'], isNot(contains('turn_done')));
      f.tap('valid');
      await f.changed();
      expect(await f.service.takePendingNotificationRoute(), isNull);
      await f.service.syncPreferences(prefs.copyWith(enabled: false));
      expect(f.native['master'], isFalse);
    },
  );
  test(
    'edited saved login invalidates native authority instead of reusing old credentials',
    () async {
      f.seed(active: true);
      await f.service.initialize(f.manager);
      await f.manager.updateApiKey(f.connection.id, 'changed-login');
      await f.service.refresh();
      expect(f.native['enabled'], isFalse);
      expect(f.service.status, contains('changed'));
    },
  );
}
