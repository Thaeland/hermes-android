import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/streaming_rate_tracker.dart';

void main() {
  group('StreamingRateTracker', () {
    final t0 = DateTime(2026, 9, 27, 12);

    StreamingRateTracker build() => StreamingRateTracker();

    test('returns null until the window has enough span', () {
      final tracker = build();
      // First sample: no span yet.
      expect(tracker.addSample(40, at: t0), isNull);
      // 1s span < 4s window * 0.5 min fraction -> still null.
      expect(
        tracker.addSample(40, at: t0.add(const Duration(seconds: 1))),
        isNull,
      );
      // 2s span >= 2s threshold -> rate available.
      final rate = tracker.addSample(
        40,
        at: t0.add(const Duration(seconds: 2)),
      );
      expect(rate, isNotNull);
    });

    test('computes chars/4 over the sliding window', () {
      final tracker = StreamingRateTracker(smoothing: 0);
      tracker.addSample(80, at: t0);
      // Window holds both samples at the 4s boundary: 160 chars / 4 / 4s
      // = 10 tok/s.
      final rate = tracker.addSample(
        80,
        at: t0.add(const Duration(seconds: 4)),
      );
      expect(rate, closeTo(10.0, 0.01));
    });

    test('prunes samples older than the window', () {
      final tracker = StreamingRateTracker(smoothing: 0);
      // Huge early burst that will fall out of the window.
      tracker.addSample(100000, at: t0);
      tracker.addSample(80, at: t0.add(const Duration(seconds: 10)));
      // Only the last two samples (within 4s) count: 80 chars over ~0s span
      // is too short; add one more 4s later.
      final rate = tracker.addSample(
        80,
        at: t0.add(const Duration(seconds: 14)),
      );
      // Window holds samples at 10s and 14s: 160 chars / 4 / 4s = 10 tok/s.
      expect(rate, closeTo(10.0, 0.01));
    });

    test('EMA smooths toward newer samples', () {
      final tracker = StreamingRateTracker(smoothing: 0.5);
      tracker.addSample(80, at: t0);
      final first = tracker.addSample(
        80,
        at: t0.add(const Duration(seconds: 4)),
      );
      expect(first, closeTo(10.0, 0.01));
      // Sudden 4x speed: window now holds t4+t8 (400 chars / 4 / 4s = 25);
      // EMA = 0.5*25 + 0.5*10 = 17.5.
      final second = tracker.addSample(
        320,
        at: t0.add(const Duration(seconds: 8)),
      );
      expect(second, closeTo(17.5, 0.01));
    });

    test('reset clears history', () {
      final tracker = build();
      tracker.addSample(80, at: t0);
      tracker.addSample(80, at: t0.add(const Duration(seconds: 4)));
      expect(tracker.lastRate, isNotNull);
      tracker.reset();
      expect(tracker.lastRate, isNull);
      expect(tracker.addSample(80, at: t0), isNull);
    });

    test('zero-length deltas do not create samples', () {
      final tracker = build();
      expect(tracker.addSample(0, at: t0), isNull);
      expect(tracker.addSample(-5, at: t0), isNull);
    });

    test('format rounds to whole tok/s and rejects non-positive', () {
      expect(StreamingRateTracker.format(42.4), '42 tok/s');
      expect(StreamingRateTracker.format(42.6), '43 tok/s');
      expect(StreamingRateTracker.format(0.2), isNull);
      expect(StreamingRateTracker.format(0), isNull);
      expect(StreamingRateTracker.format(null), isNull);
      expect(StreamingRateTracker.format(double.nan), isNull);
    });
  });
}
