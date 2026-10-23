import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/config_backup_service.dart';
import 'package:hermes_android/core/services/notification_prefs.dart';
import 'package:hermes_android/core/services/turn_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/recording_turn_notification_sink.dart';

class HeldNotificationSink extends RecordingTurnNotificationSink {
  Completer<void>? initializationGate;
  Completer<void>? permissionGate;
  Completer<void>? permissionCheckGate;
  Completer<void>? showGate;
  bool failCancel = false;

  @override
  Future<void> initialize() async {
    await super.initialize();
    await initializationGate?.future;
  }

  @override
  Future<bool?> requestPermission() async {
    final result = await super.requestPermission();
    await permissionGate?.future;
    return result;
  }

  @override
  Future<bool?> checkPermission() async {
    final result = await super.checkPermission();
    await permissionCheckGate?.future;
    return result;
  }

  @override
  Future<void> show(TurnNotification notification) async {
    await showGate?.future;
    await super.show(notification);
  }

  @override
  Future<void> cancel(int id) async {
    if (failCancel) throw StateError('platform temporarily unavailable');
    await super.cancel(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HeldNotificationSink sink;
  late TurnNotificationService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    notificationPrefs.value = NotificationPrefs.defaults;
    sink = HeldNotificationSink();
    service = TurnNotificationService(sink: sink);
  });

  Future<void> show({
    String connection = 'c',
    String local = 'draft',
    String? stored,
    String title = 'First title',
    String turn = 't1',
    String status = 'Working',
  }) => service.showOngoingChat(
    connectionId: connection,
    localSessionId: local,
    storedSessionId: stored,
    title: title,
    turnId: turn,
    status: status,
  );

  test(
    'IDs are fixed UTF-8 vectors in disjoint ongoing/terminal/native namespaces',
    () {
      expect(TurnNotificationService.notificationIdFor('turn-42'), 0x16f2ad33);
      expect(
        TurnNotificationService.ongoingChatNotificationIdFor(
          connectionId: 'c',
          localSessionId: 'draft',
        ),
        0x2bf52da7,
      );
      expect(
        TurnNotificationService.ongoingChatNotificationIdFor(
          connectionId: '账户',
          localSessionId: '💬',
        ),
        0x2c4e4a25,
      );
      expect(TurnNotificationService.notificationIdFor('4705'), isNot(4705));
    },
  );

  test(
    'concurrent initialization and foreground permission are single-flight',
    () async {
      sink.initializationGate = Completer<void>();
      sink.permissionGate = Completer<void>();
      final headless = service.ensureInitialized();
      final foreground = service.ensureInitialized(requestPermission: true);
      final sibling = service.ensureInitialized(requestPermission: true);
      await pumpEventQueue();
      expect(sink.initializeCount, 1);
      expect(sink.permissionRequestCount, 0);
      sink.initializationGate!.complete();
      await pumpEventQueue();
      expect(sink.permissionRequestCount, 1);
      sink.permissionGate!.complete();
      await Future.wait([headless, foreground, sibling]);
      expect(sink.initializeCount, 1);
      expect(sink.permissionRequestCount, 1);
    },
  );

  test(
    'headless show does not request permission; later foreground can',
    () async {
      await show();
      expect(sink.permissionRequestCount, 0);
      expect(sink.permissionCheckCount, 0);
      await service.ensureInitialized(requestPermission: true);
      expect(sink.permissionRequestCount, 1);
    },
  );

  test(
    'passive authorization observes external grant and revocation without another prompt',
    () async {
      sink.permissionResult = false;
      await service.ensureInitialized(requestPermission: true);
      await show();
      expect(sink.shown, isEmpty);
      sink.permissionResult = true;
      await service.refreshAuthorization();
      await show();
      expect(sink.shown.single.ongoing, isTrue);
      expect(
        await service.sendTestNotification(title: 'test', body: 'test'),
        isTrue,
      );
      sink.permissionResult = false;
      await service.refreshAuthorization();
      final before = sink.shown.length;
      await show();
      expect(
        await service.sendTestNotification(title: 'test', body: 'test'),
        isFalse,
      );
      expect(sink.shown, hasLength(before));
      expect(sink.cancelled, contains(sink.shown.first.id));
      expect(sink.permissionRequestCount, 1);
      expect(sink.permissionCheckCount, 4);
    },
  );

  test(
    'explicit foreground test passively discovers an external grant without resume',
    () async {
      sink.permissionResult = false;
      expect(
        await service.sendTestNotification(title: 'test', body: 'test'),
        isFalse,
      );
      sink.permissionResult = true;
      expect(
        await service.sendTestNotification(title: 'test', body: 'test'),
        isTrue,
      );
      expect(sink.permissionRequestCount, 1);
    },
  );

  test(
    'passive authorization reads are singleflight and fail closed without prompting',
    () async {
      sink.permissionCheckGate = Completer<void>();
      sink.permissionResult = false;
      final first = service.refreshAuthorization();
      final second = service.refreshAuthorization();
      await pumpEventQueue();
      expect(sink.permissionCheckCount, 1);
      sink.permissionCheckGate!.complete();
      await Future.wait([first, second]);
      expect(service.permissionGranted, isFalse);
      sink.permissionCheckError = StateError('platform unavailable');
      await service.refreshAuthorization();
      expect(service.permissionGranted, isFalse);
      expect(sink.permissionRequestCount, 0);
    },
  );

  test(
    'passive read cannot overwrite the result of a newer explicit prompt',
    () async {
      sink.permissionResult = false;
      sink.permissionCheckGate = Completer<void>();
      final passive = service.refreshAuthorization();
      await pumpEventQueue();
      expect(sink.permissionCheckCount, 1);
      sink.permissionResult = true;
      await service.ensureInitialized(requestPermission: true);
      expect(service.permissionGranted, isTrue);
      sink.permissionCheckGate!.complete();
      await passive;
      expect(service.permissionGranted, isTrue);
      expect(sink.permissionRequestCount, 1);
    },
  );

  for (final initiallyGranted in [false, true]) {
    test(
      'new passive demand coalesces one fresh trailing read $initiallyGranted',
      () async {
        sink.permissionResult = initiallyGranted;
        sink.permissionCheckGate = Completer<void>();
        final first = service.refreshAuthorization();
        await pumpEventQueue();
        expect(sink.permissionCheckCount, 1);
        sink.permissionResult = !initiallyGranted;
        final second = service.refreshAuthorization();
        final third = service.refreshAuthorization();
        await pumpEventQueue();
        expect(sink.permissionCheckCount, 1);
        sink.permissionCheckGate!.complete();
        await Future.wait([first, second, third]);
        expect(sink.permissionCheckCount, 2);
        expect(service.permissionGranted, !initiallyGranted);
        expect(sink.permissionRequestCount, 0);
      },
    );
  }

  test(
    'quiet ongoing updates retain identity through stored binding, rename and new turn',
    () async {
      await show();
      await show(
        stored: 'stored-7',
        title: 'Renamed',
        turn: 't2',
        status: 'Reconnecting',
      );
      expect(sink.shown, hasLength(2));
      expect(sink.shown.map((n) => n.id).toSet(), hasLength(1));
      final latest = sink.shown.last;
      expect(latest.title, 'Renamed');
      expect(latest.body, 'Reconnecting');
      expect(latest.ongoing, isTrue);
      expect(latest.silent, isTrue);
      expect(latest.onlyAlertOnce, isTrue);
      expect(latest.importance, TurnNotificationImportance.low);
      expect(latest.channel.id, 'hermes_ongoing_chats');
      expect(jsonDecode(latest.payload), {
        'connectionId': 'c',
        'sessionId': 'stored-7',
        'localSessionId': 'draft',
        'turnId': 't2',
      });
      final route = NotificationRoute.fromResponse(
        NotificationResponse(
          payload: latest.payload,
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );
      expect(route.sessionId, 'stored-7');
      expect(route.localSessionId, 'draft');
      expect(route.turnId, 't2');
      expect(jsonDecode(sink.shown.first.payload)['sessionId'], 'draft');
    },
  );

  test('same local id on different connections is distinct', () async {
    await show();
    await show(connection: 'other');
    expect(sink.shown.map((n) => n.id).toSet(), hasLength(2));
  });

  test(
    'settling one chat leaves sibling and terminal notifications alone',
    () async {
      await show();
      await show(local: 'sibling');
      final firstId = sink.shown.first.id;
      final siblingId = sink.shown.last.id;
      await service.showTurnCompleted(
        title: 'Done',
        turnSummary: 'Finished',
        turnId: 't1',
      );
      final terminalId = sink.shown.last.id;
      await service.cancelOngoingChat(
        connectionId: 'c',
        localSessionId: 'draft',
      );
      expect(sink.cancelled, [firstId]);
      expect(sink.cancelled, isNot(contains(siblingId)));
      expect(sink.cancelled, isNot(contains(terminalId)));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList(TurnNotificationService.ongoingIdsStorageKey),
        ['$siblingId'],
      );
      expect(sink.cancelAllCount, 0);
    },
  );

  test(
    'all ongoing cleanup cancels tracked IDs only and persists empty index',
    () async {
      await show();
      await show(local: 'sibling');
      final ids = sink.shown.map((n) => n.id).toSet();
      await service.cancelAllOngoingChats();
      expect(sink.cancelled.toSet(), ids);
      expect(sink.cancelAllCount, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList(TurnNotificationService.ongoingIdsStorageKey),
        isEmpty,
      );
    },
  );

  test(
    'cancel queued behind a held show cannot be undone by its late completion',
    () async {
      sink.showGate = Completer<void>();
      final showing = show();
      await pumpEventQueue();
      final cancelling = service.cancelOngoingChat(
        connectionId: 'c',
        localSessionId: 'draft',
      );
      await pumpEventQueue();
      expect(sink.cancelled, isEmpty);
      sink.showGate!.complete();
      await Future.wait([showing, cancelling]);
      expect(sink.cancelled, [sink.shown.single.id]);
    },
  );

  test(
    'master switch gates optional ongoing and existing terminal kind preferences still work',
    () async {
      notificationPrefs.value = NotificationPrefs.defaults.copyWith(
        enabled: false,
      );
      await show();
      await service.showTurnCompleted(
        title: 'Done',
        turnSummary: 'Finished',
        turnId: 't1',
      );
      await service.showTurnFailed(
        title: 'Failed',
        turnSummary: 'Error',
        turnId: 't1',
      );
      expect(sink.shown, isEmpty);
      notificationPrefs.value = NotificationPrefs.defaults.copyWith(
        kind: HermesNotificationKind.turnDone,
        kindValue: false,
      );
      await service.showTurnCompleted(
        title: 'Done',
        turnSummary: 'Finished',
        turnId: 't1',
      );
      expect(sink.shown, isEmpty);
      await show(); // ongoing is not the completion-kind toggle
      expect(sink.shown.single.ongoing, isTrue);
    },
  );

  test(
    'denied permission suppresses ongoing posts and test notification reports false',
    () async {
      sink.permissionResult = false;
      await service.ensureInitialized(requestPermission: true);
      await show();
      expect(sink.shown, isEmpty);
      expect(
        await service.sendTestNotification(title: 'test', body: 'test'),
        isFalse,
      );
    },
  );

  test(
    'permission failure is not a grant and can be retried in foreground',
    () async {
      sink.permissionError = StateError('missing channel');
      await service.ensureInitialized(requestPermission: true);
      expect(service.permissionGranted, isFalse);
      sink.permissionError = null;
      await service.ensureInitialized(requestPermission: true);
      expect(service.permissionGranted, isTrue);
      expect(sink.permissionRequestCount, 2);
    },
  );

  test(
    'restart cleans only known ongoing orphans, even with corrupt foreign IDs',
    () async {
      await show();
      final oldId = sink.shown.single.id;
      final terminalId = TurnNotificationService.notificationIdFor('terminal');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(TurnNotificationService.ongoingIdsStorageKey, [
        '$oldId',
        '4705',
        '$terminalId',
        '-1',
        'garbage',
        '2147483647',
      ]);
      final restartedSink = HeldNotificationSink();
      final restarted = TurnNotificationService(sink: restartedSink);
      await restarted.ensureInitialized();
      expect(restartedSink.cancelled, [oldId]);
      expect(restartedSink.cancelAllCount, 0);
      expect(
        prefs.getStringList(TurnNotificationService.ongoingIdsStorageKey),
        isEmpty,
      );
      expect(
        ConfigBackupService.isBackedUpKey(
          TurnNotificationService.ongoingIdsStorageKey,
        ),
        isFalse,
      );
    },
  );

  test('failed orphan cleanup retains index for a later retry', () async {
    final oldId = TurnNotificationService.ongoingChatNotificationIdFor(
      connectionId: 'c',
      localSessionId: 'old',
    );
    SharedPreferences.setMockInitialValues({
      TurnNotificationService.ongoingIdsStorageKey: ['$oldId'],
    });
    sink.failCancel = true;
    await service.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(TurnNotificationService.ongoingIdsStorageKey), [
      '$oldId',
    ]);
    sink.failCancel = false;
    await service.ensureInitialized();
    expect(sink.cancelled, [oldId]);
    expect(
      prefs.getStringList(TurnNotificationService.ongoingIdsStorageKey),
      isEmpty,
    );
  });

  test(
    'bookkeeping contains numeric IDs only, never routing or chat content',
    () async {
      await show(
        stored: 'private-stored',
        title: 'Private title',
        status: 'Private status',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {TurnNotificationService.ongoingIdsStorageKey});
      expect(
        prefs.getStringList(TurnNotificationService.ongoingIdsStorageKey),
        ['${sink.shown.single.id}'],
      );
    },
  );

  test('plain notifications retain backward-compatible flags', () {
    const notice = TurnNotification(
      id: 1,
      title: 't',
      body: 'b',
      payload: '',
      channel: TurnNotificationService.turnChannel,
    );
    expect(notice.ongoing, isFalse);
    expect(notice.silent, isFalse);
    expect(notice.onlyAlertOnce, isFalse);
  });

  test(
    'Android passive authorization uses only areNotificationsEnabled, never a prompt',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      final pluginSink = PluginTurnNotificationSink();
      expect(await pluginSink.checkPermission(), isTrue);
      expect(calls, ['areNotificationsEnabled']);
    },
  );

  test('plugin sink maps ongoing flags to real Android arguments', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final pluginSink = PluginTurnNotificationSink();
    await pluginSink.initialize();
    await pluginSink.show(
      TurnNotification(
        id: 42,
        title: 't',
        body: 'b',
        payload: '{}',
        channel: TurnNotificationService.ongoingChannel,
        ongoing: true,
        silent: true,
        onlyAlertOnce: true,
        importance: TurnNotificationImportance.low,
      ),
    );
    final args = calls.singleWhere((c) => c.method == 'show').arguments as Map;
    final android = args['platformSpecifics'] as Map;
    expect(android['ongoing'], isTrue);
    expect(android['autoCancel'], isFalse);
    expect(android['silent'], isTrue);
    expect(android['onlyAlertOnce'], isTrue);
    expect(android['playSound'], isFalse);
    expect(android['enableVibration'], isFalse);
    expect(android['importance'], Importance.low.value);
  });
}
