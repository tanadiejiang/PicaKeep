/// Bounded phase timings for the independent profile harness. These are not
/// presentation times; the harness separately joins image builds to FrameTiming.
class ReaderRasterDiagnostics {
  static final _samples = <Map<String, num>>[];

  static List<Map<String, num>> drainSamples() {
    final result = List<Map<String, num>>.of(_samples);
    _samples.clear();
    return result;
  }

  static void record(Map<String, num> sample) {
    if (_samples.length >= 256) _samples.removeAt(0);
    _samples.add(sample);
  }
}
