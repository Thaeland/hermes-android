import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/workspace_screen.dart';
import 'package:hermes_android/core/services/background_work_prefs.dart';
import 'package:hermes_android/core/services/connection_keepalive_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/mobile_push_service.dart';
import 'package:hermes_android/core/services/normal_gateway_application_session.dart';
import 'package:hermes_android/core/services/normal_gateway_pending_store.dart';
import 'package:hermes_android/core/services/notification_prefs.dart';
import 'package:hermes_android/core/services/turn_notification_service.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/recording_turn_notification_sink.dart';

class _Secrets implements CredentialStore {
  final values = <String, String>{};
  @override
  String? readCached(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _HeldSink extends RecordingTurnNotificationSink {
  Completer<void>? initialization;
  Completer<NotificationResponse?>? launch;
  @override
  Future<NotificationResponse?> takeInitialLaunchResponse() =>
      launch?.future ?? super.takeInitialLaunchResponse();
  @override
  Future<void> initialize() async {
    await super.initialize();
    await initialization?.future;
  }
}

class _RootFixture {
  final sink = _HeldSink();
  late final notifications = TurnNotificationService(sink: sink);
  final controller = GatewayTurnApplicationController();
  late ConnectionManager manager;
  late SavedConnection connection;
  late MobilePushService push;
  final channel = const MethodChannel('test/root/mobile_push');
  final native = <String, dynamic>{'enabled': false};
  final nativeCalls = <String>[];
  final pushRequests = <http.Request>[];
  final lookups = <http.Request>[];
  final keepalive = <String>[];
  List<Map<String, dynamic>> feed = [];
  Completer<http.Response>? detail;
  Completer<Map<String, dynamic>>? snapshot;
  final rpc = Completer<void>();
  int submissions = 0;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    manager = ConnectionManager(prefs, credentialStore: _Secrets());
    await manager.saveConnection(
      'Root fixture',
      'https://root.invalid',
      443,
      'root-api-key',
      gatewayPrefix: '/gateway',
      dashboardPrefix: '/dash',
      dashboardUsername: 'test-user',
      dashboardPassword: 'test-password',
      gatewayProfile: 'test-profile',
    );
    connection = manager.getConnections().single;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ConnectionKeepAliveService.channel, (
          call,
        ) async {
          keepalive.add(call.method);
          return true;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call.method);
          switch (call.method) {
            case 'snapshot':
              if (snapshot != null) return snapshot!.future;
              return Map<String, dynamic>.from(native);
            case 'preferences':
              native.addAll(Map<String, dynamic>.from(call.arguments as Map));
              return Map<String, dynamic>.from(native);
            case 'takeTap':
              return native.remove('tap');
            case 'disable':
              native['enabled'] = false;
              native['active'] = false;
              native.remove('tap');
              return Map<String, dynamic>.from(native);
            default:
              throw StateError('Unexpected native mutation ${call.method}');
          }
        });
    push = MobilePushService(
      supported: true,
      channel: channel,
      clientFactory: (c) => DashboardClient(
        host: c.host,
        port: c.dashboardPort,
        useHttps: c.useHttps,
        pathPrefix: c.dashboardPrefix!,
        username: c.dashboardUsername,
        password: c.dashboardPassword,
        gatewayProfile: c.gatewayProfile,
        httpClient: MockClient((request) async {
          pushRequests.add(request);
          if (request.url.path == '/dash/auth/password-login') {
            return http.Response(
              '{}',
              200,
              headers: {
                'set-cookie': 'hermes_session_at=root-cookie; HttpOnly',
              },
            );
          }
          expectSync(request.method, 'GET');
          expectSync(
            request.headers['Cookie'],
            'hermes_session_at=root-cookie',
          );
          expectSync(request.url.path, '/dash/api/plugins/mobile-push/events');
          return http.Response(
            jsonEncode({'events': feed, 'has_more': false, 'next_cursor': '1'}),
            200,
          );
        }),
      ),
    );
  }

  ApiClient client(SavedConnection c) => ApiClient(
    baseUrl: c.baseUrl,
    apiKey: c.apiKey,
    pathPrefix: c.gatewayPrefix!,
    httpClient: MockClient((request) async {
      lookups.add(request);
      expectSync(request.method, 'GET');
      expectSync(request.headers['Authorization'], 'Bearer root-api-key');
      expectSync(request.url.path, '/gateway/api/sessions');
      return detail?.future ?? response();
    }),
  );

  http.Response response({String id = 'stored'}) => http.Response(
    jsonEncode({
      'data': [
        {
          'id': id,
          'title': 'Verified root chat',
          'model': '',
          'message_count': 2,
          'started_at': 1,
          'source': 'mobile',
        },
      ],
      'has_more': false,
    }),
    200,
  );

  NotificationResponse tap({String id = 'stored'}) => NotificationResponse(
    payload: jsonEncode({'connectionId': connection.id, 'sessionId': id}),
    notificationResponseType: NotificationResponseType.selectedNotification,
  );

  void seedPush({String id = 'stored', String kind = 'input'}) {
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    native.addAll({
      'enabled': true,
      'active': true,
      'connection': connection.id,
      'binding': MobilePushService.binding(connection),
      'installation': 'root-installation',
      'nonce': 'root-nonce',
      'generation': 7,
      'revision': 1,
      'endpoint': 'https://push.invalid/opaque',
      'sessions': [id],
      'tap': {
        'nonce': 'root-nonce',
        'generation': 7,
        'revision': 1,
        'event_id': 'event-1',
        'expires_at': expiry,
      },
    });
    feed = [
      {
        'event_id': 'event-1',
        'session_id': id,
        'kind': kind,
        'expires_at': expiry,
      },
    ];
  }

  HermesApp app({
    Future<void> Function()? loadPolicy,
    GatewayTurnApplicationController? owner,
  }) => HermesApp(
    connManager: manager,
    notifications: notifications,
    mobilePush: push,
    turnApplicationController: owner ?? controller,
    notificationClientFactory: client,
    loadBackgroundPolicy: loadPolicy,
  );

  Future<NormalGatewayApplicationSession> normal() async {
    final normal = controller.normalSessionFor(
      connection,
      notifications: notifications,
      submit:
          ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submissions++;
            onSent();
            await rpc.future;
          },
      resume: ({required localSessionId, required storedSessionId}) async =>
          ResumedGatewaySession(runtimeSessionId: 'runtime', running: true),
      history: (_) async => [],
    );
    await normal.ready;
    normal.chatFor('local', storedSessionId: 'stored', title: 'Owned chat');
    return normal;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await pumps(tester);
    await controller.close();
    if (!rpc.isCompleted) rpc.complete();
    await pumps(tester);
    push.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ConnectionKeepAliveService.channel, null);
  }
}

Future<void> pumps(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 350));
}

class _HeldStore extends NormalGatewayPendingStore {
  final gate = Completer<List<NormalGatewayPendingMarker>>();
  @override
  Future<List<NormalGatewayPendingMarker>> load(String scope) => gate.future;
}

class _HeldOwner extends GatewayTurnApplicationController {
  late final NormalGatewayApplicationSession normal;
  _HeldOwner(SavedConnection c, _HeldStore store, TurnNotificationService n) {
    normal = NormalGatewayApplicationSession(
      connection: c,
      scope: 'held',
      pendingStore: store,
      notifications: n,
      submit:
          ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async => throw StateError('Must never submit'),
      resume: ({required localSessionId, required storedSessionId}) async =>
          throw StateError('Must never resume'),
      history: (_) async => [],
    );
  }
  @override
  NormalGatewayApplicationSession normalSessionFor(
    SavedConnection c, {
    NormalGatewayPromptSubmit? submit,
    NormalGatewayResume? resume,
    NormalGatewayHistory? history,
    TurnNotificationService? notifications,
  }) => normal;
  @override
  Future<void> close() async {
    await normal.close();
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    notificationPrefs.value = NotificationPrefs.defaults;
    backgroundWorkEnabled.value = true;
    pendingNotificationApprovals.value = const [];
  });
  tearDown(() {
    notificationResponseHandler = null;
    pendingNotificationApprovals.value = const [];
  });

  for (final cold in [true, false]) {
    for (final ongoing in [true, false]) {
      testWidgets(
        '${cold ? 'cold' : 'warm'} ${ongoing ? 'ongoing' : 'completion'} tap opens authenticated chat from fresh connection objects',
        (tester) async {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          final f = _RootFixture();
          await f.initialize();
          final normal = await f.normal();
          expect(
            identical(
              f.manager.getConnections().single,
              f.manager.getConnections().single,
            ),
            isFalse,
          );
          if (ongoing) {
            await f.notifications.showOngoingChat(
              connectionId: f.connection.id,
              localSessionId: 'local',
              title: 'Owned chat',
              turnId: 'turn',
              status: 'running',
            );
          } else {
            await f.notifications.ensureInitialized();
            await f.notifications.showKind(
              kind: HermesNotificationKind.turnDone,
              title: 'Response ready',
              body: 'Owned chat',
              eventId: 'turn',
              sessionId: 'stored',
              connectionId: f.connection.id,
              payload: f.tap().payload,
            );
          }
          final tap = NotificationResponse(
            payload: f.sink.shown.single.payload,
            notificationResponseType:
                NotificationResponseType.selectedNotification,
          );
          if (cold) f.sink.initialLaunchResponse = tap;
          await tester.pumpWidget(f.app());
          if (!cold) notificationResponseHandler!(tap);
          await pumps(tester);
          expect(f.lookups, hasLength(1));
          final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
          expect(chat.session.id, 'stored');
          expect(
            normal.findChat(chat.session.id),
            same(normal.findChat('local')),
          );
          expect(f.submissions, 0);
          // Both alias forms, including the other transport, reuse this route.
          notificationResponseHandler!(f.tap(id: 'local'));
          notificationResponseHandler!(f.tap());
          await pumps(tester);
          expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
          expect(f.lookups, hasLength(1));
          await f.close(tester);
        },
      );
    }
  }

  for (final removed in [false, true]) {
    testWidgets(
      'connection ${removed ? 'removed' : 'edited'} during authenticated lookup cannot route',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final f = _RootFixture();
        await f.initialize();
        await f.normal();
        f.detail = Completer<http.Response>();
        await tester.pumpWidget(f.app());
        notificationResponseHandler!(f.tap());
        await pumps(tester);
        expect(f.lookups, hasLength(1));
        if (removed) {
          await f.manager.deleteConnection(f.connection.id);
        } else {
          await f.manager.updateApiKey(f.connection.id, 'replacement-key');
        }
        f.detail!.complete(f.response());
        await pumps(tester);
        expect(find.byType(ChatScreen), findsNothing);
        expect(find.byType(WorkspaceScreen), findsNothing);
        expect(f.manager.prefs.getString('last_connection_id'), isNull);
        await f.close(tester);
      },
    );
  }

  testWidgets('connection edit during normal.ready prevents even the lookup', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final f = _RootFixture();
    await f.initialize();
    final store = _HeldStore();
    final owner = _HeldOwner(f.connection, store, f.notifications);
    await tester.pumpWidget(f.app(owner: owner));
    notificationResponseHandler!(f.tap());
    await pumps(tester);
    expect(f.lookups, isEmpty);
    await f.manager.updateApiKey(f.connection.id, 'edited-before-ready');
    store.gate.complete([]);
    await pumps(tester);
    expect(f.lookups, isEmpty);
    expect(find.byType(ChatScreen), findsNothing);
    await f.close(tester);
  });

  testWidgets('push input tap is consumed once and never approves or submits', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final f = _RootFixture();
    await f.initialize();
    await f.normal();
    f.seedPush();
    await tester.pumpWidget(f.app());
    await pumps(tester);
    expect(
      tester.widget<ChatScreen>(find.byType(ChatScreen)).session.id,
      'stored',
    );
    expect(f.lookups, hasLength(1));
    expect(f.nativeCalls.where((m) => m == 'takeTap'), hasLength(1));
    expect(pendingNotificationApprovals.value, isEmpty);
    expect(f.submissions, 0);
    expect(
      f.pushRequests.where(
        (r) => r.method != 'GET' && !r.url.path.endsWith('/password-login'),
      ),
      isEmpty,
    );
    await f.push.refresh();
    notificationResponseHandler!(f.tap());
    await pumps(tester);
    expect(f.lookups, hasLength(1));
    expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
    await f.close(tester);
  });

  testWidgets(
    'revoked push consent while detail is pending rejects navigation',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      await f.normal();
      f.seedPush();
      f.detail = Completer<http.Response>();
      await tester.pumpWidget(f.app());
      await pumps(tester);
      expect(f.lookups, hasLength(1));
      await f.push.disable();
      f.detail!.complete(f.response());
      await pumps(tester);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(WorkspaceScreen), findsNothing);
      expect(pendingNotificationApprovals.value, isEmpty);
      expect(f.submissions, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'connection edit during push authority await is fenced after validation',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      await f.normal();
      f.seedPush();
      f.detail = Completer<http.Response>();
      await tester.pumpWidget(f.app());
      await pumps(tester);
      expect(f.lookups, hasLength(1));
      f.snapshot = Completer<Map<String, dynamic>>();
      f.detail!.complete(f.response());
      await pumps(tester);
      await f.manager.updateApiKey(
        f.connection.id,
        'changed-during-native-read',
      );
      f.snapshot!.complete(Map<String, dynamic>.from(f.native));
      await pumps(tester);
      expect(find.byType(ChatScreen), findsNothing);
      await f.close(tester);
    },
  );

  testWidgets(
    'already paused root holds disabled persisted policy before protection',
    (tester) async {
      final f = _RootFixture();
      await f.initialize();
      final normal = await f.normal();
      final chat = normal.findChat('local')!;
      final turn = chat.submitPrepared(
        reservation: chat.reserve()!,
        text: 'test',
        localContent: 'test',
      );
      turn.ignore();
      await pumps(tester);
      expect(f.controller.hasActiveTurn, isTrue);
      await f.manager.prefs.setBool(BackgroundWorkPrefsStore.storageKey, false);
      final policy = Completer<void>();
      var policyEntered = false;
      var policyLoaded = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpWidget(
        f.app(
          loadPolicy: () async {
            policyEntered = true;
            await policy.future;
            await BackgroundWorkPrefsStore.load();
            policyLoaded = true;
          },
        ),
      );
      // A paused binding suppresses ordinary frame scheduling. Force the
      // mount to exercise an initial lifecycle state, not a later transition.
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      await pumps(tester);
      expect(f.keepalive.where((m) => m == 'start'), isEmpty);
      expect(f.sink.shown.where((n) => n.ongoing), isEmpty);
      expect(f.sink.permissionRequestCount, 0);
      policy.complete();
      await pumps(tester);
      expect(policyEntered, isTrue);
      expect(policyLoaded, isTrue);
      expect(backgroundWorkEnabled.value, isFalse);
      expect(f.keepalive.where((m) => m == 'start'), isEmpty);
      expect(f.sink.shown.where((n) => n.ongoing), isEmpty);
      await BackgroundWorkPrefsStore.setEnabled(true);
      await pumps(tester);
      expect(f.keepalive.where((m) => m == 'start'), hasLength(1));
      expect(f.sink.shown.where((n) => n.ongoing), isNotEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumps(tester);
      expect(f.sink.permissionRequestCount, 1);
      expect(f.sink.cancelAllCount, 0);
      await f.close(tester);
      await turn;
    },
  );

  testWidgets('normal and push taps single-flight the same canonical chat', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final f = _RootFixture();
    await f.initialize();
    await f.normal();
    f.detail = Completer<http.Response>();
    await tester.pumpWidget(f.app());
    notificationResponseHandler!(f.tap(id: 'local'));
    await pumps(tester);
    f.seedPush();
    await f.push.refresh();
    await pumps(tester);
    expect(f.lookups, hasLength(1));
    f.detail!.complete(f.response());
    await pumps(tester);
    expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
    expect(f.submissions, 0);
    expect(pendingNotificationApprovals.value, isEmpty);
    await f.close(tester);
  });

  testWidgets('late cold launch response cannot override a newer warm tap', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final f = _RootFixture();
    await f.initialize();
    await f.normal();
    f.sink.launch = Completer<NotificationResponse?>();
    await tester.pumpWidget(f.app());
    notificationResponseHandler!(f.tap());
    await pumps(tester);
    expect(find.byType(ChatScreen), findsOneWidget);
    f.sink.launch!.complete(f.tap(id: 'older-cold-session'));
    await pumps(tester);
    expect(f.lookups, hasLength(1));
    expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(WorkspaceScreen), findsNothing);
    await f.close(tester);
  });

  testWidgets('tap on the open chat cancels a different older pending route', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final f = _RootFixture();
    await f.initialize();
    await f.normal();
    await tester.pumpWidget(f.app());
    notificationResponseHandler!(f.tap());
    await pumps(tester);
    f.detail = Completer<http.Response>();
    notificationResponseHandler!(f.tap(id: 'other-session'));
    await pumps(tester);
    expect(f.lookups, hasLength(2));
    notificationResponseHandler!(f.tap(id: 'local'));
    f.detail!.complete(f.response(id: 'other-session'));
    await pumps(tester);
    expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
    expect(
      tester.widget<ChatScreen>(find.byType(ChatScreen)).session.id,
      'stored',
    );
    await f.close(tester);
  });

  testWidgets(
    'held optional push initialization never delays the first root frame',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      f.snapshot = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(f.app());
      await pumps(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(f.sink.permissionRequestCount, 1);
      expect(f.nativeCalls, contains('snapshot'));
      expect(f.nativeCalls, isNot(contains('permission')));
      expect(f.nativeCalls, isNot(contains('enable')));
      expect(f.pushRequests, isEmpty);
      f.snapshot!.complete(Map<String, dynamic>.from(f.native));
      await pumps(tester);
      await f.close(tester);
    },
  );

  testWidgets(
    'a newer push tap supersedes pending lookup without stranding its singleflight',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      await f.normal();
      f.seedPush();
      final oldDetail = Completer<http.Response>();
      f.detail = oldDetail;
      await tester.pumpWidget(f.app());
      await pumps(tester);
      expect(f.lookups, hasLength(1));
      f.seedPush();
      (f.native['tap'] as Map)['event_id'] = 'event-2';
      f.feed.single['event_id'] = 'event-2';
      await f.push.refresh();
      await pumps(tester);
      f.detail = null;
      oldDetail.complete(f.response());
      await pumps(tester);
      expect(f.lookups, hasLength(2));
      expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
      expect(f.submissions, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'startup orphan cleanup cannot cancel a new notification queued during initialization',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      final orphan = TurnNotificationService.ongoingChatNotificationIdFor(
        connectionId: 'removed',
        localSessionId: 'old',
      );
      await f.manager.prefs.setStringList(
        TurnNotificationService.ongoingIdsStorageKey,
        [orphan.toString()],
      );
      f.sink.initialization = Completer<void>();
      await tester.pumpWidget(f.app());
      final showing = f.notifications.showOngoingChat(
        connectionId: f.connection.id,
        localSessionId: 'new',
        title: 'New work',
        turnId: 'new-turn',
        status: 'running',
      );
      f.sink.initialization!.complete();
      await pumps(tester);
      await showing;
      final fresh = f.sink.shown.single;
      expect(f.sink.cancelled, contains(orphan));
      expect(f.sink.cancelled, isNot(contains(fresh.id)));
      expect(f.sink.cancelAllCount, 0);
      await f.close(tester);
      expect(f.sink.cancelled, isNot(contains(fresh.id)));
    },
  );

  testWidgets(
    'lookup finishing after root disposal cannot navigate or leak a handler',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      await f.normal();
      f.detail = Completer<http.Response>();
      await tester.pumpWidget(f.app());
      notificationResponseHandler!(f.tap());
      await pumps(tester);
      expect(f.lookups, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      expect(notificationResponseHandler, isNull);
      f.detail!.complete(f.response());
      await pumps(tester);
      expect(find.byType(ChatScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await f.close(tester);
    },
  );

  testWidgets(
    'notification master changes resync unchanged active work and terminal survives cleanup',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      final normal = await f.normal();
      await tester.pumpWidget(f.app());
      await pumps(tester);
      final chat = normal.findChat('local')!;
      final turn = chat.submitPrepared(
        reservation: chat.reserve()!,
        text: 'test',
        localContent: 'test',
      );
      turn.ignore();
      await pumps(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumps(tester);
      final ongoing = f.sink.shown.lastWhere((n) => n.ongoing);
      await NotificationPrefsStore.setEnabled(false);
      await pumps(tester);
      expect(f.sink.cancelled, contains(ongoing.id));
      final before = f.sink.shown.length;
      await NotificationPrefsStore.setEnabled(true);
      await pumps(tester);
      expect(f.sink.shown.length, greaterThan(before));
      normal.receiveEvent(
        'local',
        StreamEvent(type: 'turn.end', data: {'status': 'completed'}),
      );
      f.rpc.complete();
      await pumps(tester);
      final terminal = f.sink.shown.lastWhere((n) => !n.ongoing);
      expect(f.controller.hasActiveTurn, isFalse);
      expect(f.sink.cancelled, isNot(contains(terminal.id)));
      expect(f.sink.cancelAllCount, 0);
      expect(f.keepalive.last, 'stop');
      await f.close(tester);
      await turn;
    },
  );

  testWidgets(
    'foreground permission waits for init, hidden root defers permission and tap',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      f.sink.initialization = Completer<void>();
      await tester.pumpWidget(f.app());
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(f.sink.permissionRequestCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      notificationResponseHandler!(f.tap());
      f.sink.initialization!.complete();
      await pumps(tester);
      expect(f.sink.permissionRequestCount, 0);
      expect(f.lookups, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumps(tester);
      expect(f.sink.permissionRequestCount, 1);
      expect(find.byType(ChatScreen), findsOneWidget);
      await f.close(tester);
    },
  );

  testWidgets(
    'root remount retains process push singleton and detaches old handler',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final f = _RootFixture();
      await f.initialize();
      await tester.pumpWidget(f.app());
      await pumps(tester);
      await tester.pumpWidget(const SizedBox());
      await pumps(tester);
      expect(notificationResponseHandler, isNull);
      f.seedPush();
      await f.push.refresh();
      final replacement = GatewayTurnApplicationController();
      await tester.pumpWidget(f.app(owner: replacement));
      await pumps(tester);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(f.lookups, hasLength(1));
      expect(pendingNotificationApprovals.value, isEmpty);
      await f.close(tester);
    },
  );
}
