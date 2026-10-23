import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Device-local drafts retain their existing string keys and empty-delete
/// semantics. Aliases and clear markers contain identities only, never prompts.
abstract final class ComposerDraftStore {
  static const _prefix = 'composer_draft';
  static const _aliasPrefix = 'composer_draft_alias';
  static const _writtenPrefix = 'composer_draft_written';

  // Every instance/controller addresses the same preferences. Release completed
  // flights so a disposed fake-async zone is never retained by a static tail.
  static Future<void>? _tail;
  static Future<T> _serial<T>(Future<T> Function() operation) {
    final previous = _tail;
    final result = previous == null
        ? operation()
        : previous.then((_) => operation());
    final flight = result.then<void>((_) {}, onError: (Object _) {});
    _tail = flight;
    unawaited(
      flight.then((_) {
        if (identical(_tail, flight)) _tail = null;
      }),
    );
    return result;
  }

  static String _key(
    String connectionId,
    String sessionId, [
    String prefix = _prefix,
  ]) {
    final namespace = base64Url
        .encode(utf8.encode('$connectionId\u0000$sessionId'))
        .replaceAll('=', '');
    return '$prefix.$namespace';
  }

  static String _resolve(
    SharedPreferences prefs,
    String connection,
    String id,
  ) {
    final visited = <String>{};
    while (visited.add(id)) {
      final next = prefs.getString(_key(connection, id, _aliasPrefix));
      if (next == null || next == id) break;
      id = next;
    }
    return id;
  }

  static Future<String?> read({
    required String connectionId,
    required String sessionId,
  }) => _serial(() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = _resolve(prefs, connectionId, sessionId);
      final value = prefs.getString(_key(connectionId, id));
      return value == null || value.trim().isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  });

  static Future<void> save({
    required String connectionId,
    required String sessionId,
    required String text,
    bool Function()? isCurrent,
  }) => _serial(() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (isCurrent?.call() == false) return;
      final id = _resolve(prefs, connectionId, sessionId);
      await _write(prefs, connectionId, id, text);
    } catch (_) {
      // Best-effort: storage failure must not break the composer.
    }
  });

  static Future<void> _write(
    SharedPreferences prefs,
    String connection,
    String id,
    String text,
  ) async {
    // A clear is a deliberate value, even though the string entry is removed.
    // Without this marker, a delayed local alias migration can resurrect it.
    final key = _key(connection, id);
    final marker = _key(connection, id, _writtenPrefix);
    final oldText = prefs.getString(key);
    final oldMarker = prefs.getBool(marker);
    try {
      final saved = text.trim().isEmpty
          ? await prefs.remove(key)
          : await prefs.setString(key, text);
      if (!saved || !await prefs.setBool(marker, true)) {
        throw StateError('Composer draft write was rejected.');
      }
    } catch (_) {
      // SharedPreferences updates its cache even when the platform rejects a
      // write. Restore that cache as well as making a best-effort disk rollback.
      if (oldText == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, oldText);
      }
      if (oldMarker == null) {
        await prefs.remove(marker);
      } else {
        await prefs.setBool(marker, oldMarker);
      }
      rethrow;
    }
  }

  /// Canonical data (including an explicit clear) wins over a legacy local key.
  /// Serialization makes migration, normal saves and restart reads one order.
  static Future<void> bind({
    required String connectionId,
    required String localSessionId,
    required String storedSessionId,
    bool Function()? isCurrent,
  }) => _serial(() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (isCurrent?.call() == false) return;
      final local = _resolve(prefs, connectionId, localSessionId);
      final stored = _resolve(prefs, connectionId, storedSessionId);
      if (local == stored) return;
      final targetKey = _key(connectionId, stored);
      if (!prefs.containsKey(targetKey) &&
          prefs.getBool(_key(connectionId, stored, _writtenPrefix)) != true) {
        final draft = prefs.getString(_key(connectionId, local));
        if (draft != null) await _write(prefs, connectionId, stored, draft);
      }
      // Write the redirect last: a failed target write leaves the source usable.
      if (isCurrent?.call() == false) return;
      if (!await prefs.setString(
        _key(connectionId, local, _aliasPrefix),
        stored,
      )) {
        return;
      }
      await prefs.remove(_key(connectionId, local));
      await prefs.remove(_key(connectionId, local, _writtenPrefix));
    } catch (_) {
      // Best-effort. The next binding can retry migration.
    }
  });

  static Future<void> remove({
    required String connectionId,
    required String sessionId,
  }) => save(connectionId: connectionId, sessionId: sessionId, text: '');

  static Future<void> removeConnection(String connectionId) =>
      _serial(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final marker = '$connectionId\u0000';
          for (final key in prefs.getKeys()) {
            if (![
              _prefix,
              _aliasPrefix,
              _writtenPrefix,
            ].any((prefix) => key.startsWith('$prefix.'))) {
              continue;
            }
            final encoded = key.substring(key.indexOf('.') + 1);
            try {
              final decoded = utf8.decode(
                base64Url.decode(base64Url.normalize(encoded)),
              );
              if (decoded.startsWith(marker)) await prefs.remove(key);
            } catch (_) {
              // Ignore malformed foreign entries.
            }
          }
        } catch (_) {
          // Best-effort.
        }
      });
}
