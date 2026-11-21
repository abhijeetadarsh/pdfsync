import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// Scroll-feel tuning for the reader, kept in one place. See
/// docs/performance.md ("Scroll feel").

/// Mouse-wheel multiplier (pdfrx default 0.2). Linux reports 53 px per notch,
/// so 3.0 ≈ 160 px per notch before acceleration – a little more than
/// Chrome / Okular, which suits reading pages rather than web text.
const double kWheelStep = 3.0;

/// Fling friction after a finger / middle-button drag is released. pdfrx's
/// default (InteractiveViewer's 0.0000135) stops a flick almost at once: the
/// fling travels velocity / |ln(drag)| ≈ v / 11, i.e. a fast 3000 px/s flick
/// moves only ~270 px where a native Android list moves ~1150 px. 0.07 gives
/// v / 2.66 (≈1130 px for that flick, ≈1.2 s glide) – close to native.
const double kFlingDrag = 0.07;

/// Pages rendered ahead of / behind the viewport, in viewport heights (pdfrx
/// default 1.0). Fast scrolling then reaches pages that are already rendered
/// instead of blank placeholders.
const double kCacheExtent = 2.0;

/// Smooth wheel scrolling with acceleration: each notch glides (exponential
/// ease-out, pdfrx's physics delegate), and notches that come in quick
/// succession in the same direction step progressively further – like
/// browsers – so spinning the wheel crosses a long book quickly while a single
/// notch stays precise. Trackpad / high-resolution deltas (small, continuous)
/// are passed through unchanged.
class AcceleratedWheelScrollProvider extends PdfViewerScrollInteractionDelegateProvider {
  const AcceleratedWheelScrollProvider({this.panFriction = 22, this.zoomFriction = 14});

  /// Glide speed – higher settles faster (95 % of a notch in 3/friction s).
  final double panFriction;
  final double zoomFriction;

  @override
  PdfViewerScrollInteractionDelegate create() => _AcceleratedWheelScroll(
        PdfViewerScrollInteractionDelegateProviderPhysics(panFriction: panFriction, zoomFriction: zoomFriction)
            .create(),
      );

  @override
  bool operator ==(Object other) =>
      other is AcceleratedWheelScrollProvider && other.panFriction == panFriction && other.zoomFriction == zoomFriction;

  @override
  int get hashCode => Object.hash(panFriction, zoomFriction);
}

class _AcceleratedWheelScroll implements PdfViewerScrollInteractionDelegate {
  _AcceleratedWheelScroll(this._inner);

  final PdfViewerScrollInteractionDelegate _inner;
  final WheelAccelerator _accel = WheelAccelerator();
  final Stopwatch _clock = Stopwatch()..start();

  @override
  void init(PdfViewerController controller, TickerProvider vsync) => _inner.init(controller, vsync);

  @override
  void dispose() => _inner.dispose();

  @override
  void stop() {
    _accel.reset();
    _inner.stop();
  }

  @override
  void pan(Offset delta, PdfViewerLayoutMetrics layoutMetrics) =>
      _inner.pan(delta * _accel.boost(delta, _clock.elapsed), layoutMetrics);

  @override
  void zoom(double scale, Offset focalPoint, PdfViewerLayoutMetrics layoutMetrics) =>
      _inner.zoom(scale, focalPoint, layoutMetrics);
}

/// Wheel acceleration from the recent wheel *rate*, so it doesn't matter
/// whether the platform delivers each notch separately or merges several into
/// one event. Recent distance decays with a 0.3 s time constant; a single
/// notch or slow notches (≥ ~250 ms apart) stay at 1×; at ~80 ms per notch the
/// third notch goes ~1.3× and steady spinning reaches ~2.5×; fast spinning
/// (≤ 40 ms per notch) quickly reaches 3×.
class WheelAccelerator {
  /// Deltas at least this big (after [kWheelStep]) are wheel notches;
  /// trackpad / high-resolution deltas are smaller and never accelerated.
  static const double notch = 40;
  static const double _tau = 0.3; // seconds
  static const double _free = 300; // recent travel that still scrolls at 1×
  static const double _perBoost = 250; // further travel per +1× boost
  static const double maxBoost = 3.0;

  double _recent = 0;
  Duration? _last;
  double _lastSign = 0;

  void reset() {
    _recent = 0;
    _last = null;
  }

  double boost(Offset delta, Duration now) {
    final d = delta.distance;
    if (d < notch) return 1.0;
    final sign = (delta.dy != 0 ? delta.dy : delta.dx).sign;
    final last = _last;
    if (last == null || sign != _lastSign) {
      _recent = 0;
    } else {
      final dt = (now - last).inMicroseconds / 1e6;
      _recent *= math.exp(-dt / _tau);
    }
    _recent += d;
    _last = now;
    _lastSign = sign;
    return (1 + (_recent - _free) / _perBoost).clamp(1.0, maxBoost);
  }
}
