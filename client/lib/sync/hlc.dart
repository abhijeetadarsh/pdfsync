/// Hybrid Logical Clock.
///
/// Produces timestamps like `1731650000000-0003-k3j9x2pq` that:
///  * sort lexicographically in causal order (fixed-width fields),
///  * stay monotonic even if the wall clock jumps backwards,
///  * are unique across devices (node id suffix breaks ties).
///
/// The server compares them as plain strings for last-writer-wins.
class Hlc {
  Hlc(this.node, {String? last}) {
    if (last != null) receive(last);
  }

  final String node;
  int _ms = 0;
  int _counter = 0;

  /// Correction applied to the local wall clock, learned from the server's
  /// `serverTime`. Keeps a device with a wrong clock from losing (or always
  /// winning) every conflict.
  int offsetMs = 0;

  static final _re = RegExp(r'^(\d{13})-([0-9a-f]{4})-([A-Za-z0-9_]+)$');

  String now() {
    final wall = DateTime.now().millisecondsSinceEpoch + offsetMs;
    if (wall > _ms) {
      _ms = wall;
      _counter = 0;
    } else {
      _counter++;
      if (_counter > 0xffff) {
        _ms++;
        _counter = 0;
      }
    }
    return toString();
  }

  /// Merge a timestamp seen from another device so our next event sorts after it.
  void receive(String hlc) {
    final m = _re.firstMatch(hlc);
    if (m == null) return;
    final ms = int.parse(m.group(1)!);
    final c = int.parse(m.group(2)!, radix: 16);
    if (ms > _ms || (ms == _ms && c > _counter)) {
      _ms = ms;
      _counter = c;
    }
  }

  void observeServerTime(int serverMs) {
    final local = DateTime.now().millisecondsSinceEpoch;
    final skew = serverMs - local;
    // Only correct meaningful skew; ignore network jitter.
    offsetMs = skew.abs() > 2000 ? skew : 0;
  }

  @override
  String toString() =>
      '${_ms.toString().padLeft(13, '0')}-${_counter.toRadixString(16).padLeft(4, '0')}-$node';
}
