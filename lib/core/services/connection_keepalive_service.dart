import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';

/// Keeps the Android process alive while the app is backgrounded so the
/// gateway WebSocket — and the Dart heartbeat timers that hold it open —
/// survive minimization instead of being frozen or killed by the OS.
///
/// The native side is a `specialUse` foreground service
/// (`ConnectionKeepAliveService.kt`). Dart owns the policy, and the
/// service is bounded to user-visible work: it runs only while an
/// unresolved chat turn needs the socket, never for an idle or merely
/// reconnecting connection. Stop conditions: the turn settles while
/// backgrounded ([onTurnActivityChanged] with no active turn), the app
/// resumes (a foregrounded app never needs it), or the app detaches (no
/// isolate survives to stop it later). This bounded lifetime is what
/// keeps the persistent notification defensible under Play's
/// foreground-service criteria: it protects work the user started, and
/// it ends when that work ends.
///
/// A refused start (Android 12+ background-start limits on some OEMs) is
/// not an error: the transport's reconnect-on-resume loop remains the
/// fallback, so callers must never gate UI on [isActive].
class ConnectionKeepAliveService {
  static const MethodChannel channel =
      MethodChannel('com.hermesagent.hermes_android/keepalive');

  bool _active = false;
  bool _starting = false;
  bool _backgrounded = false;

  /// A start requested while another start is in flight. The in-flight
  /// guard would otherwise swallow it, and the in-flight start — now
  /// stale — would stop the service, leaving a backgrounded app without
  /// keep-alive. The latest requested state must win instead.
  bool _pendingStart = false;
  int _cycle = 0;

  /// True when the native keep-alive service was started and not yet stopped.
  bool get isActive => _active;

  Future<void> start() async {
    if (_active) return;
    if (_starting) {
      _pendingStart = true;
      return;
    }
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
    } finally {
      // Must reset even if an unexpected error escapes the typed invoke
      // (a malformed native reply raises TypeError): a leaked _starting
      // wedges the service permanently — every later start would only
      // record _pendingStart and nothing would ever consume it.
      _starting = false;
    }
    if (cycle != _cycle) {
      if (_pendingStart) {
        // A background landed after a stop raced this start (rapid
        // minimize → resume → minimize). The latest request is a start,
        // so honour it rather than tearing the service down. The stop
        // that bumped the cycle already reached the native side, so no
        // compensating stop is owed here.
        _pendingStart = false;
        return start();
      }
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
    _pendingStart = false;
    _active = false;
    await _sendStop();
  }

  /// The app-root lifecycle policy, kept here so it is testable without
  /// pumping the whole app: backgrounding with an unresolved turn starts
  /// the service; resume stops it (foreground never needs it); detach stops
  /// it too — after `detached` no Dart isolate survives to stop it, and
  /// an orphaned foreground service would pin the process with a
  /// permanent notification protecting a dead socket.
  void onAppLifecycleState(
    AppLifecycleState state, {
    required bool hasActiveTurn,
  }) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.detached:
        _backgrounded = false;
        unawaited(stop());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Leave-the-foreground transitions fire in sequence; the first
        // one still runs while the FGS start is permitted. Only worth a
        // service when there is actually a turn in flight to protect.
        _backgrounded = true;
        if (hasActiveTurn) unawaited(start());
    }
  }

  /// The bounded-lifetime stop condition: called whenever the app-wide
  /// active-turn state may have changed. While backgrounded, the service
  /// follows the work — a turn settling ends the notification then, not
  /// at resume; a turn becoming active (e.g. a recovered or detached turn)
  /// gains protection. In the foreground the service is never needed.
  void onTurnActivityChanged(bool hasActiveTurn) {
    if (!_backgrounded) return;
    if (hasActiveTurn) {
      unawaited(start());
    } else {
      unawaited(stop());
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
