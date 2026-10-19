import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';

/// Keeps the Android process alive while the app is backgrounded so the
/// gateway WebSocket — and the Dart heartbeat timers that hold it open —
/// survive minimization instead of being frozen or killed by the OS.
///
/// The native side is a `specialUse` foreground service
/// (`ConnectionKeepAliveService.kt`). Dart owns the policy: start when the
/// app leaves the foreground while a gateway socket is live, stop on resume
/// (a foregrounded app never needs it) and on detach (no isolate survives
/// to stop it later). A refused start (Android 12+ background-start limits
/// on some OEMs) is not an error: the transport's reconnect-on-resume loop
/// remains the fallback, so callers must never gate UI on [isActive].
class ConnectionKeepAliveService {
  static const MethodChannel channel =
      MethodChannel('com.hermesagent.hermes_android/keepalive');

  bool _active = false;
  bool _starting = false;
  int _cycle = 0;

  /// True when the native keep-alive service was started and not yet stopped.
  bool get isActive => _active;

  Future<void> start() async {
    if (_active || _starting) return;
    _starting = true;
    final cycle = ++_cycle;
    var started = false;
    try {
      started = await channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException {
      started = false;
    } on MissingPluginException {
      // Non-Android host (tests, desktop): nothing to keep alive.
      started = false;
    }
    _starting = false;
    if (cycle != _cycle) {
      // A stop landed while this start was in flight (fast minimize +
      // return). Its stop may have raced ahead of the native start, so
      // send another to guarantee the service ends stopped.
      if (started) await _sendStop();
      return;
    }
    _active = started;
  }

  Future<void> stop() async {
    // Unconditional: Dart's view of the native state can diverge (hot
    // restart, engine reattach, a stop that raced a start), and a stop
    // that always reaches the native side is the only recovery path.
    // Native stopService on a stopped service is a cheap no-op.
    _cycle++;
    _active = false;
    await _sendStop();
  }

  /// The app-root lifecycle policy, kept here so it is testable without
  /// pumping the whole app: backgrounding with a live socket starts the
  /// service; resume stops it (foreground never needs it); detach stops
  /// it too — after `detached` no Dart isolate survives to stop it, and
  /// an orphaned foreground service would pin the process with a
  /// permanent notification protecting a dead socket.
  void onAppLifecycleState(
    AppLifecycleState state, {
    required bool hasLiveSocket,
  }) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.detached:
        unawaited(stop());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Leave-the-foreground transitions fire in sequence; the first
        // one still runs while the FGS start is permitted. Only worth a
        // service when there is actually a socket to protect.
        if (hasLiveSocket) unawaited(start());
    }
  }

  Future<void> _sendStop() async {
    try {
      await channel.invokeMethod<bool>('stop');
    } on PlatformException {
      // The service dies with the process anyway; nothing to undo.
    } on MissingPluginException {
      // Non-Android host (tests, desktop): nothing was started.
    }
  }
}
