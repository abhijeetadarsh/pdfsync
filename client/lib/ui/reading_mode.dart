import 'package:material_ui/material_ui.dart';

/// Page tints for comfortable reading. Applied with
/// `PdfViewerParams.pageImageColorFilter`, so only the rendered PDF page is
/// recoloured – highlights, ink and notes keep their true colours.
enum ReadingMode {
  original('Original', Color(0xFFFFFFFF), Color(0xFF000000), null),
  // Tinted modes multiply each channel: white paper becomes the tint, black
  // text stays black.
  paper('Paper', Color(0xFFFAF6EE), Color(0xFF000000), _Tint(0.98, 0.965, 0.933)),
  sepia('Sepia', Color(0xFFF4E8CE), Color(0xFF3B2A14), _Tint(0.957, 0.91, 0.808, darkText: Color(0xFF3B2A14))),
  green('Green', Color(0xFFCCE8CF), Color(0xFF1B2E1C), _Tint(0.8, 0.91, 0.81)),
  dim('Dim', Color(0xFFB9B9B9), Color(0xFF000000), _Tint(0.725, 0.725, 0.725)),
  // Night inverts the page (white → near-black, black → light grey).
  night('Night', Color(0xFF1C1C1E), Color(0xFFD6D6D6), _Invert());

  const ReadingMode(this.label, this.paperColor, this.inkColor, this._filter);
  final String label;

  /// Preview colours for the picker.
  final Color paperColor;
  final Color inkColor;
  final _Filter? _filter;

  ColorFilter? get colorFilter => _filter?.build();

  static ReadingMode byName(String? name) =>
      ReadingMode.values.firstWhere((m) => m.name == name, orElse: () => ReadingMode.original);
}

sealed class _Filter {
  const _Filter();
  ColorFilter build();
}

class _Tint extends _Filter {
  const _Tint(this.r, this.g, this.b, {this.darkText});
  final double r, g, b;

  /// Optional colour for black (default: stays black). Linear blend between
  /// [darkText] at in=0 and the tint at in=255.
  final Color? darkText;

  @override
  ColorFilter build() {
    final d = darkText;
    final dr = d == null ? 0.0 : d.r * 255, dg = d == null ? 0.0 : d.g * 255, db = d == null ? 0.0 : d.b * 255;
    return ColorFilter.matrix([
      r - dr / 255, 0, 0, 0, dr, //
      0, g - dg / 255, 0, 0, dg, //
      0, 0, b - db / 255, 0, db, //
      0, 0, 0, 1, 0,
    ]);
  }
}

class _Invert extends _Filter {
  const _Invert();
  // Smart invert: rotate hue by 180°, then invert brightness
  // (out = 214 - 0.82 * hue180(in)). The two hue flips cancel, so a white page
  // becomes near-black and black text light grey, but blue links stay blue and
  // red stays red instead of turning yellow/cyan like a plain invert.
  @override
  ColorFilter build() => const ColorFilter.matrix([
        0.4707, -1.1726, -0.1181, 0, 214, //
        -0.3493, -0.3526, -0.1181, 0, 214, //
        -0.3493, -1.1726, 0.7019, 0, 214, //
        0, 0, 0, 1, 0,
      ]);
}
