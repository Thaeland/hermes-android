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
