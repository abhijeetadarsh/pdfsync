import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfsync/ui/input_policy.dart';

PointerDownEvent down(int p, PointerDeviceKind kind, {int buttons = kPrimaryButton}) =>
    PointerDownEvent(pointer: p, kind: kind, buttons: buttons);

void main() {
  test('mouse: left draws, middle and right navigate', () {
    final pol = InputPolicy();
    expect(pol.down(down(1, PointerDeviceKind.mouse)), PointerRole.draw);
    pol.up(1);
    expect(pol.down(down(2, PointerDeviceKind.mouse, buttons: kMiddleMouseButton)), PointerRole.navigate);
    pol.up(2);
    expect(pol.down(down(3, PointerDeviceKind.mouse, buttons: kSecondaryMouseButton)), PointerRole.navigate);
  });

  test('finger-only device: one finger draws, a second turns both into navigation', () {
    final pol = InputPolicy();
    expect(pol.down(down(1, PointerDeviceKind.touch)), PointerRole.draw);
    expect(pol.down(down(2, PointerDeviceKind.touch)), PointerRole.navigate);
    expect(pol.roleOf(1), PointerRole.navigate);
    expect(pol.hasDrawPointer, isFalse);
    pol
      ..up(1)
      ..up(2);
    expect(pol.down(down(3, PointerDeviceKind.touch)), PointerRole.draw);
  });

  test('stylus draws; afterwards fingers navigate; palm ignored while writing', () {
    final pol = InputPolicy();
    expect(pol.down(down(1, PointerDeviceKind.stylus)), PointerRole.draw);
    expect(pol.down(down(2, PointerDeviceKind.touch)), PointerRole.ignore);
    expect(pol.hasNavigatePointer, isFalse);
    pol
      ..up(1)
      ..up(2);
    expect(pol.penSeen, isTrue);
    expect(pol.down(down(3, PointerDeviceKind.touch)), PointerRole.navigate);
  });

  test('palm already down when the pen lands is ignored', () {
    final pol = InputPolicy()..penSeen = true;
    expect(pol.down(down(1, PointerDeviceKind.touch)), PointerRole.navigate);
    expect(pol.down(down(2, PointerDeviceKind.stylus)), PointerRole.draw);
    expect(pol.roleOf(1), PointerRole.ignore);
    expect(pol.hasNavigatePointer, isFalse);
  });

  test('down is idempotent (layer and reader both register the pointer)', () {
    final pol = InputPolicy();
    final e = down(1, PointerDeviceKind.touch);
    expect(pol.down(e), PointerRole.draw);
    expect(pol.down(e), PointerRole.draw);
    expect(pol.down(down(2, PointerDeviceKind.touch)), PointerRole.navigate);
  });
}
