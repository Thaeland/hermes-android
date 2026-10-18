import 'package:flutter/services.dart';

/// Keeps the Android process alive while the app is backgrounded so the
/// gateway WebSocket — and the Dart heartbeat timers that hold it open —
/// survive minimization instead of being frozen or killed by the OS.
///
/// The native side is a `specialUse` foreground service
/// (`ConnectionKeepAliveService.kt`). Dart owns the policy: start when the
/// app leaves the foreground while gateway clients are open, stop on resume
/// (a foregrounded app never needs it). A refused start (Android 12+
/// background-start limits on some OEMs) is not an error: the transport's
/// reconnect-on-resume loop remains the fallback, so callers must never
/// gate UI on [isActive].
class ConnectionKeepAliveService {
  static const MethodChannel channel =
      MethodChannel('com.hermesagent.hermes_android/keepalive');

  bool _active = false;

  /// True when the native keep-alive service was started and not yet stopped.
  bool get isActive => _active;

  Future<void> start() async {
    if (_active) return;
    try {
      _active = await channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException {
      _active = false;
    } on MissingPluginException {
      // Non-Android host (tests, desktop): nothing to keep alive.
    }
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    try {
      await channel.invokeMethod<bool>('stop');
    } on PlatformException {
      // The service dies with the process anyway; nothing to undo.
    } on MissingPluginException {
      // Non-Android host (tests, desktop): nothing was started.
    }
  }
}
