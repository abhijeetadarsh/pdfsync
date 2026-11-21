import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Frame-time logging for performance work. Off unless the app is built with
/// `--dart-define=PDFSYNC_PERF=true`; then every ~2 s of activity it prints
/// `PERF frames=… build avg/p90/max … raster avg/p90/max … janky=…`
/// (janky = frames whose build or raster took longer than 16 ms).
const bool kPerfLog = bool.fromEnvironment('PDFSYNC_PERF');

void startPerfLog() {
  if (!kPerfLog) return;
  final build = <double>[], raster = <double>[];
  var windowStart = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final t in timings) {
      build.add(t.buildDuration.inMicroseconds / 1000);
      raster.add(t.rasterDuration.inMicroseconds / 1000);
    }
    if (DateTime.now().difference(windowStart).inMilliseconds < 2000) return;
    String stats(List<double> v) {
      final s = [...v]..sort();
      final avg = s.reduce((a, b) => a + b) / s.length;
      return '${avg.toStringAsFixed(1)}/${s[(s.length * 0.9).floor().clamp(0, s.length - 1)].toStringAsFixed(1)}/'
          '${s.last.toStringAsFixed(1)}';
    }

    var janky = 0;
    for (var i = 0; i < build.length; i++) {
      if (build[i] > 16 || raster[i] > 16) janky++;
    }
    debugPrint('PERF frames=${build.length} build ${stats(build)} raster ${stats(raster)} janky=$janky');
    build.clear();
    raster.clear();
    windowStart = DateTime.now();
  });
}
