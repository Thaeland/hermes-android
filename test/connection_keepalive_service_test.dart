// Background keep-alive contract: the Dart side must drive the native
// foreground service exactly once per background/foreground cycle, must
// treat a refused or missing native start as a silent no-op (the
// transport's reconnect-on-resume loop is the fallback), and must never
// lose a stop that races an in-flight start (a stuck foreground service
// means a permanent notification while the app is in the foreground).
import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_keepalive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockChannel(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ConnectionKeepAliveService.channel, handler);
  }

  tearDown(() => mockChannel(null));

  test('start/stop drive the native service once each and are idempotent',
      () async {
    final calls = <String>[];
    mockChannel((call) async {
      calls.add(call.method);
      return true;
    });

    final service = ConnectionKeepAliveService();
    await service.start();
    await service.start();
    expect(service.isActive, isTrue);
    await service.stop();
    await service.stop();
    expect(service.isActive, isFalse);
    // Second start is deduped; stops always reach the native side (an
    // extra no-op stop is the price of guaranteed recovery), so the
    // native state — not the IPC count — is the idempotency contract.
    expect(calls, ['start', 'stop', 'stop']);
  });

  test('a refused native start leaves the service inactive', () async {
    final calls = <String>[];
    mockChannel((call) async {
      calls.add(call.method);
      return false;
    });

    final service = ConnectionKeepAliveService();
    await service.start();
    expect(service.isActive, isFalse);
    // stop() must still reach the native side even when Dart believes
    // nothing is running: state can diverge (hot restart, engine
    // reattach), and an unconditional stop is the only recovery path.
    // Native stopService on a stopped service is a cheap no-op.
    await service.stop();
    expect(calls, ['start', 'stop']);
  });

  test('missing native plugin (non-Android host) is a silent no-op', () async {
    // No mock handler: invokeMethod throws MissingPluginException.
    final service = ConnectionKeepAliveService();
    await service.start();
    expect(service.isActive, isFalse);
    await service.stop();
  });

  test('a stop racing an in-flight start still stops the service', () async {
    // Minimize-then-immediately-return: the native start is still pending
    // when the resume arrives. If stop() only looks at the settled state
    // it no-ops, the start then succeeds, and the foreground service (and
    // its notification) stays up for the whole foreground session.
    final startResult = Completer<bool>();
    final calls = <String>[];
    mockChannel((call) async {
      calls.add(call.method);
      if (call.method == 'start') return startResult.future;
      return true;
    });

    final service = ConnectionKeepAliveService();
    final starting = service.start();
    await pumpEventQueue();
    await service.stop();
    startResult.complete(true);
    await starting;
    await pumpEventQueue();

    expect(calls, containsAllInOrder(['start', 'stop']));
    expect(service.isActive, isFalse);
  });

  test('lifecycle policy: background-with-socket starts; resume and detach stop', () async {
    final calls = <String>[];
    mockChannel((call) async {
      calls.add(call.method);
      return true;
    });

    final service = ConnectionKeepAliveService();

    // Backgrounding with nothing connected must not start the service.
    service.onAppLifecycleState(
      AppLifecycleState.inactive,
      hasLiveSocket: false,
    );
    await pumpEventQueue();
    expect(calls, isEmpty);

    // Backgrounding with a live socket starts it.
    service.onAppLifecycleState(
      AppLifecycleState.inactive,
      hasLiveSocket: true,
    );
    await pumpEventQueue();
    expect(calls, ['start']);

    // Exiting the app via Back must stop it: after `detached` there is no
    // Dart isolate left to ever stop it, and the FGS would pin the
    // process with a permanent notification protecting a dead socket.
    service.onAppLifecycleState(
      AppLifecycleState.detached,
      hasLiveSocket: true,
    );
    await pumpEventQueue();
    expect(calls, containsAllInOrder(['start', 'stop']));
    expect(service.isActive, isFalse);

    // Resume stops too (a foregrounded app never needs the service).
    service.onAppLifecycleState(
      AppLifecycleState.inactive,
      hasLiveSocket: true,
    );
    await pumpEventQueue();
    service.onAppLifecycleState(
      AppLifecycleState.resumed,
      hasLiveSocket: true,
    );
    await pumpEventQueue();
    expect(calls, containsAllInOrder(['start', 'stop', 'start', 'stop']));
  });
}
