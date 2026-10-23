import 'dart:async';

import 'connection_manager.dart';
import 'local_chat_pin_store.dart';

typedef SessionScanProgress = void Function(List<Session> sessions);

/// Shares only an in-flight scan; a later refresh always reads fresh history.
/// Both conversation browsers observe the same unfiltered source so legacy
/// cron identities are not lost behind a source=cron request.
class SessionBrowserLoader {
  final ApiClient api;
  final Future<List<String>> Function() loadPins;
  final Future<List<Session>> Function()? sessionsLoader;
  final _listeners = <SessionScanProgress>{};
  Future<List<Session>>? _inFlight;
  List<Session>? _progress;
  bool _closed = false;

  SessionBrowserLoader({
    required this.api,
    required this.loadPins,
    this.sessionsLoader,
  });

  Future<List<Session>> load({SessionScanProgress? onProgress}) async {
    if (_closed) throw StateError('Session browser is closed');
    if (onProgress != null) {
      _listeners.add(onProgress);
      final previous = _progress;
      if (_inFlight != null && previous != null) onProgress(previous);
    }
    try {
      return await (_inFlight ??= _scan().whenComplete(() {
        _inFlight = null;
        _progress = null;
      }));
    } finally {
      if (onProgress != null) _listeners.remove(onProgress);
    }
  }

  void _publish(Iterable<Session> sessions) {
    if (_closed) return;
    final snapshot = List<Session>.unmodifiable(sessions);
    _progress = snapshot;
    for (final listener in _listeners.toList()) {
      listener(snapshot);
    }
  }

  Future<List<Session>> _scan() async {
    final custom = sessionsLoader;
    if (custom != null) {
      final sessions = await custom();
      _publish(sessions);
      return sessions;
    }
    final first = await api.getSessionsPage(limit: 5);
    if (_closed) throw StateError('Session browser is closed');
    _publish(first.sessions);
    const pageSize = 100;
    final all = <String, Session>{};
    var offset = 0;
    var pinBound = 0;
    var zeroNewPages = 0;
    while (!_closed) {
      final page = await api.getSessionsPage(limit: pageSize, offset: offset);
      if (_closed) throw StateError('Session browser is closed');
      var newRows = 0;
      for (final session in page.sessions) {
        if (!all.containsKey(session.id)) newRows++;
        all[session.id] = session;
      }
      _publish(all.values);
      final pinsOnPage = page.sessions
          .where((session) => session.pinned)
          .length;
      if (pinsOnPage > pinBound) pinBound = pinsOnPage;
      // Stock appends pins beyond limit and can report has_more=false when
      // pins occupy the base window. Repeated all-pin windows are not EOF.
      if (newRows == 0) {
        zeroNewPages++;
        final required = pinBound == 0 ? 1 : pinBound ~/ pageSize + 1;
        if (zeroNewPages >= required) break;
      } else {
        zeroNewPages = 0;
      }
      offset += pageSize;
    }
    if (_closed) throw StateError('Session browser is closed');
    List<String> pins;
    try {
      pins = await loadPins();
    } catch (_) {
      // Device preferences are additive, never a prerequisite for history.
      pins = const [];
    }
    if (_closed) throw StateError('Session browser is closed');
    if (pins.isNotEmpty) {
      final recovered = await loadUnlistedLocalPins(
        api,
        all.values.toList(),
        pins,
      );
      if (_closed) throw StateError('Session browser is closed');
      for (final session in recovered) {
        all[session.id] = session;
      }
    }
    return List.unmodifiable(all.values);
  }

  void close() {
    _closed = true;
    _listeners.clear();
  }
}
