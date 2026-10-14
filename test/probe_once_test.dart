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

  test('forget after an await drops the cached probe so callers re-probe',
      () async {
    // The transient-failure path: the probe fails mid-flight (after an
    // await) and forgets itself so a later call re-probes instead of
    // caching a failed verdict for the app's lifetime.
    final inflight = <String, Future<void>>{};
    var runs = 0;
    await rememberProbe(inflight, 'org', (forget) async {
      runs++;
      await Future<void>.delayed(Duration.zero);
      forget();
    });
    expect(inflight.containsKey('org'), isFalse);

    await rememberProbe(inflight, 'org', (forget) async {
      runs++;
      await Future<void>.delayed(Duration.zero);
      forget();
    });
    expect(runs, 2);
  });

  test('probeRetryDelay backs off per failure and exhausts at the budget', () {
    expect(probeRetryDelay(1), const Duration(seconds: 2));
    expect(probeRetryDelay(2), const Duration(seconds: 4));
    expect(probeRetryDelay(3), isNull);
    expect(probeRetryDelay(9), isNull);
  });

  testWidgets('the scheduler fires the re-probe once the backoff elapses', (
    tester,
  ) async {
    final scheduler = ProbeRetryScheduler();
    var calls = 0;
    scheduler.schedule('org', 1, () => calls++);
    expect(calls, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    scheduler.dispose();
  });

  testWidgets('a reschedule for the same family replaces the pending timer', (
    tester,
  ) async {
    final scheduler = ProbeRetryScheduler();
    var calls = 0;
    scheduler.schedule('org', 1, () => calls++);
    // Second blip: the older timer must not fire in addition to the new one.
    scheduler.schedule('org', 2, () => calls++);
    await tester.pump(const Duration(seconds: 4));
    expect(calls, 1);
    scheduler.dispose();
  });

  testWidgets('dispose cancels pending re-probes', (tester) async {
    final scheduler = ProbeRetryScheduler();
    var calls = 0;
    scheduler.schedule('org', 1, () => calls++);
    scheduler.dispose();
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 0);
  });
}
