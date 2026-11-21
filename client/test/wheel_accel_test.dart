import 'package:flutter_test/flutter_test.dart';
import 'package:pdfsync/ui/scroll_feel.dart';

const notch = Offset(0, -159); // one Linux wheel notch × kWheelStep

List<double> spin(WheelAccelerator a, int n, int msApart, {int startMs = 0}) =>
    [for (var i = 0; i < n; i++) a.boost(notch, Duration(milliseconds: startMs + i * msApart))];

void main() {
  test('single and slow notches are not accelerated', () {
    expect(spin(WheelAccelerator(), 1, 0), [1.0]);
    expect(spin(WheelAccelerator(), 5, 250), everyElement(1.0));
  });

  test('steady spinning accelerates, faster spinning more, capped', () {
    final medium = spin(WheelAccelerator(), 10, 80).last;
    final fast = spin(WheelAccelerator(), 10, 40).last;
    expect(medium, greaterThan(1.4));
    expect(fast, greaterThan(medium));
    expect(spin(WheelAccelerator(), 40, 10).last, WheelAccelerator.maxBoost);
  });

  test('merged notches accelerate like separate ones', () {
    final separate = spin(WheelAccelerator(), 6, 40);
    final merged = WheelAccelerator();
    late double b;
    for (var i = 0; i < 3; i++) {
      b = merged.boost(notch * 2, Duration(milliseconds: i * 80));
    }
    expect(b, closeTo(separate.last, 0.6));
  });

  test('reversing direction or trackpad deltas reset / pass through', () {
    final a = WheelAccelerator();
    spin(a, 10, 30);
    expect(a.boost(-notch, const Duration(milliseconds: 320)), 1.0);
    expect(a.boost(const Offset(0, -12), const Duration(milliseconds: 330)), 1.0);
  });
}
