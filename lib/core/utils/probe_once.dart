library;

import 'dart:async';

/// Share one in-flight capability probe per family.
///
/// [run] may call [forget] synchronously (empty URL, construct failure) to
/// decline caching so a later call can try again. A remove that runs *before*
/// the future is inserted is a no-op on `Map.putIfAbsent` — this helper
/// inserts only when the probe did not decline.
Future<void> rememberProbe(
  Map<String, Future<void>> inflight,
  String family,
  Future<void> Function(void Function() forget) run,
) {
  final existing = inflight[family];
  if (existing != null) return existing;
  var declined = false;
  final future = run(() {
    declined = true;
    inflight.remove(family);
  });
  if (!declined) inflight[family] = future;
  return future;
}

/// Backoff before re-probing a family after its [failures]-th transport blip,
/// or null when the retry budget is exhausted. Time-triggered (not
/// render-triggered), so it cannot form a settle loop with rebuilds.
Duration? probeRetryDelay(int failures) {
  if (failures >= 3) return null;
  return Duration(seconds: 2 * failures);
}

/// Owns the pending backoff timers for capability re-probes, one per family.
/// A reschedule for the same family replaces the pending timer; [dispose]
/// cancels everything so a dead screen never re-probes.
class ProbeRetryScheduler {
  final Map<String, Timer> _timers = {};

  void schedule(String family, int failures, void Function() retry) {
    _timers.remove(family)?.cancel();
    final delay = probeRetryDelay(failures);
    if (delay == null) return;
    _timers[family] = Timer(delay, () {
      _timers.remove(family);
      retry();
    });
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
