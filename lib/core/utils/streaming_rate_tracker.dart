/// Estimates live output speed (tokens per second) from streamed text deltas.
///
/// The gateway streams characters, not token counts, so the rate is an
/// estimate derived from a sliding window of recent characters divided by an
/// approximate chars-per-token factor. The window naturally excludes
/// time-to-first-token latency, and the EMA smoothing keeps the displayed
/// number from flickering between deltas.
class StreamingRateTracker {
  StreamingRateTracker({
    this.window = const Duration(seconds: 4),
    this.charsPerToken = 4.0,
    this.smoothing = 0.35,
    this.minWindowFraction = 0.5,
  });

  /// Trailing interval the rate is measured over.
  final Duration window;

  /// Approximate characters per token (standard heuristic).
  final double charsPerToken;

  /// EMA weight for the newest raw sample (0 disables smoothing).
  final double smoothing;

  /// The window must span at least this fraction of [window] before a rate
  /// is reported, so the first samples don't show absurd spikes.
  final double minWindowFraction;

  final List<({DateTime at, int chars})> _samples = [];
  double? _ema;

  /// Clears all samples (call at the start of each turn).
  void reset() {
    _samples.clear();
    _ema = null;
  }

  /// Records [chars] characters arriving at [at] and returns the smoothed
  /// estimated tok/s, or null until enough time has elapsed to measure.
  double? addSample(int chars, {required DateTime at}) {
    if (chars <= 0) return _ema;
    _samples.add((at: at, chars: chars));
    _prune(at);
    if (_samples.length < 2) return null;
    final span = at.difference(_samples.first.at);
    if (span <= Duration.zero) return null;
    if (span < window * minWindowFraction) return null;
    final totalChars = _samples.fold(0, (sum, s) => sum + s.chars);
    final raw = totalChars / charsPerToken / (span.inMicroseconds / 1e6);
    _ema = _ema == null ? raw : smoothing * raw + (1 - smoothing) * _ema!;
    return _ema;
  }

  /// The last computed rate without recording a new sample.
  double? get lastRate => _ema;

  /// Formats the rate for display ("42 tok/s"), or null when unavailable.
  static String? format(double? rate) {
    if (rate == null || !rate.isFinite || rate <= 0) return null;
    final rounded = rate.round();
    if (rounded <= 0) return null;
    return '$rounded tok/s';
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(window);
    while (_samples.isNotEmpty && _samples.first.at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }
}
