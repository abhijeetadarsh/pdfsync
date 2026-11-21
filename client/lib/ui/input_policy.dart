import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Desktop (mouse + keyboard) vs. touch devices. Web follows the host OS, so a
/// browser on a laptop gets the desktop behaviour.
final bool kDesktop = switch (defaultTargetPlatform) {
  TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
  _ => false,
};

/// What a pointer does while a drawing tool (highlight, pen, note, eraser) is
/// active.
enum PointerRole {
  /// Creates / erases annotations.
  draw,

  /// Scrolls and zooms the page.
  navigate,

  /// Neither – e.g. a palm resting on the screen while the stylus writes.
  ignore,
}

/// Decides, per pointer, whether it draws or navigates. Shared by the reader
/// (which turns the viewer's pan/zoom on and off) and the annotation layers
/// (which draw), so both always agree.
///
/// * Mouse: the left button draws; middle / right navigate (pdfrx pans on a
///   middle-button drag; right-click opens the annotation menu).
/// * Stylus: always draws. Once a stylus has been used, fingers only navigate
///   (scroll / pinch) and are ignored while the pen is down (palm rejection).
/// * Finger, on a device where no stylus has been seen: one finger draws, a
///   second finger turns the gesture into scroll / pinch (the earlier finger's
///   stroke is discarded).
class InputPolicy extends ChangeNotifier {
  final Map<int, PointerRole> _roles = {};
  final Map<int, PointerDeviceKind> _kinds = {};

  /// A stylus has been used on this device during this session.
  bool penSeen = false;

  PointerRole? roleOf(int pointer) => _roles[pointer];

  bool get hasDrawPointer => _roles.containsValue(PointerRole.draw);
  bool get hasNavigatePointer => _roles.containsValue(PointerRole.navigate);

  bool _isPen(PointerDeviceKind k) => k == PointerDeviceKind.stylus || k == PointerDeviceKind.invertedStylus;

  /// Registers a pointer and returns its role. Idempotent: the annotation
  /// layer sees the event before the reader's global pointer route does.
  PointerRole down(PointerDownEvent e) {
    final known = _roles[e.pointer];
    if (known != null) return known;
    final role = _classify(e);
    _roles[e.pointer] = role;
    _kinds[e.pointer] = e.kind;
    notifyListeners();
    return role;
  }

  PointerRole _classify(PointerDownEvent e) {
    switch (e.kind) {
      case PointerDeviceKind.mouse:
        return e.buttons == kPrimaryMouseButton ? PointerRole.draw : PointerRole.navigate;
      case PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus:
        penSeen = true;
        // Fingers already down when the pen lands were a palm, not a gesture.
        for (final p in _roles.keys.toList()) {
          if (_kinds[p] == PointerDeviceKind.touch) _roles[p] = PointerRole.ignore;
        }
        return PointerRole.draw;
      case PointerDeviceKind.touch:
        if (_roles.entries.any((r) => r.value == PointerRole.draw && _isPen(_kinds[r.key]!))) {
          return PointerRole.ignore; // palm while writing
        }
        if (penSeen) return PointerRole.navigate;
        // Finger-only device: a second finger means scroll / pinch.
        final fingers = _roles.keys.where((p) => _kinds[p] == PointerDeviceKind.touch).toList();
        if (fingers.isEmpty) return PointerRole.draw;
        for (final p in fingers) {
          _roles[p] = PointerRole.navigate;
        }
        return PointerRole.navigate;
      default:
        return PointerRole.navigate;
    }
  }

  void up(int pointer) {
    if (_roles.remove(pointer) != null) {
      _kinds.remove(pointer);
      notifyListeners();
    }
  }
}
