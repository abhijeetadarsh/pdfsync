import 'package:material_ui/material_ui.dart';

/// Colors and geometry shared by the approved phone, tablet and desktop UI.
abstract final class AppTheme {
  static const lavender = Color(0xFFCBA6F7);
  static const green = Color(0xFFA6E3A1);
  static const yellow = Color(0xFFF9E2AF);
  static const blue = Color(0xFF74C7EC);
  static const pink = Color(0xFFF5C2E7);
  static const square = RoundedRectangleBorder();

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: dark ? lavender : const Color(0xFF7041A0),
      brightness: brightness,
    ).copyWith(
      primary: dark ? lavender : const Color(0xFF7041A0),
      onPrimary: dark ? const Color(0xFF11111B) : Colors.white,
      primaryContainer:
          dark ? const Color(0xFF313244) : const Color(0xFFE8DCF4),
      onPrimaryContainer: dark ? lavender : const Color(0xFF542677),
      surface: dark ? const Color(0xFF11111B) : const Color(0xFFF8F7FC),
      surfaceContainer:
          dark ? const Color(0xFF181825) : const Color(0xFFF0EDF6),
      surfaceContainerHigh:
          dark ? const Color(0xFF1E1E2E) : const Color(0xFFEAE5F1),
      surfaceContainerHighest:
          dark ? const Color(0xFF313244) : const Color(0xFFDED8E8),
      onSurface: dark ? const Color(0xFFCDD6F4) : const Color(0xFF292436),
      onSurfaceVariant:
          dark ? const Color(0xFFA6ADC8) : const Color(0xFF625A72),
      outline: dark ? const Color(0xFF585B70) : const Color(0xFF81778E),
      outlineVariant: dark ? const Color(0xFF313244) : const Color(0xFFD5CEDF),
      tertiary: dark ? yellow : const Color(0xFF785619),
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'JetBrainsMono',
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium
            ?.copyWith(fontSize: 26, fontWeight: FontWeight.w700, height: 1.25),
        titleLarge: base.textTheme.titleLarge
            ?.copyWith(fontSize: 22, fontWeight: FontWeight.w700),
        titleMedium: base.textTheme.titleMedium
            ?.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
        bodyMedium:
            base.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.5),
        bodySmall:
            base.textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.5),
        labelLarge: base.textTheme.labelLarge
            ?.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
            fontFamily: 'JetBrainsMono',
            color: scheme.onSurface,
            fontSize: 14,
            fontWeight: FontWeight.w700),
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: scheme.outlineVariant)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: scheme.outlineVariant)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: scheme.primary, width: 2)),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              shape: square, minimumSize: const Size(48, 48), elevation: 0)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              shape: square, minimumSize: const Size(48, 48))),
      textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
              shape: square, minimumSize: const Size(48, 48))),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
              shape: square, minimumSize: const Size(48, 48), iconSize: 20)),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
          shape: square,
          elevation: 0,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
          color: scheme.primary,
          linearTrackColor: scheme.surfaceContainerHighest,
          linearMinHeight: 3,
          borderRadius: BorderRadius.zero),
      dialogTheme: const DialogThemeData(shape: square),
      bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: scheme.surfaceContainer,
          shape: square,
          showDragHandle: true),
      popupMenuTheme:
          PopupMenuThemeData(color: scheme.surfaceContainerHigh, shape: square),
      snackBarTheme: SnackBarThemeData(
          backgroundColor: scheme.surfaceContainerHighest,
          contentTextStyle:
              TextStyle(color: scheme.onSurface, fontFamily: 'JetBrainsMono')),
    );
  }
}

class PdfMark extends StatelessWidget {
  const PdfMark({super.key, this.size = 44});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        color: Theme.of(context).colorScheme.primary,
        child: Text('PDF',
            style: TextStyle(
                fontSize: size * .27,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onPrimary)),
      );
}
