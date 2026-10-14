import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/probe_once.dart';

void main() {
  test('a synchronous decline is not cached', () async {
    final inflight = <String, Future<void>>{};
    await rememberProbe(inflight, 'filing', (forget) async {
      forget();
    });
    expect(inflight.containsKey('filing'), isFalse);

    var runs = 0;
    await rememberProbe(inflight, 'filing', (forget) async {
      runs++;
    });
    expect(runs, 1);
  });

  test('a successful probe is shared with later callers', () async {
    final inflight = <String, Future<void>>{};
    var runs = 0;
    Future<void> once() => rememberProbe(inflight, 'org', (_) async {
      runs++;
    });
    await Future.wait([once(), once()]);
    expect(runs, 1);
    expect(inflight.containsKey('org'), isTrue);
  });
}
