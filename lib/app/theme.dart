import 'package:flutter/material.dart';

/// Uygulamanın renk paleti: lacivert mürekkep ve İznik çinisi kobalt mavisi.
class AppPalette {
  final Color paper; // ana zemin
  final Color surface; // kartlar, alanlar
  final Color ink; // metin
  final Color muted; // ikincil metin
  final Color line; // çizgi ve kenarlıklar
  final Color accent; // çini mavisi
  final Color accentSoft; // seçili öğe zemini
  final Color onAccent;
  final Color error;

  const AppPalette({
    required this.paper,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.line,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.error,
  });

  static const light = AppPalette(
    paper: Color(0xFFF5F6F4),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF1D2733),
    muted: Color(0xFF5E6A77),
    line: Color(0xFFDCE1E6),
    accent: Color(0xFF1E5AA8),
    accentSoft: Color(0xFFE2EBF7),
    onAccent: Color(0xFFFFFFFF),
    error: Color(0xFFB3261E),
  );

  static const dark = AppPalette(
    paper: Color(0xFF12171D),
    surface: Color(0xFF1A2129),
    ink: Color(0xFFE5E9ED),
    muted: Color(0xFF97A2AD),
    line: Color(0xFF2B343E),
    accent: Color(0xFF8AB0E6),
    accentSoft: Color(0xFF1F3350),
    onAccent: Color(0xFF0E1A2B),
    error: Color(0xFFF2B8B5),
  );
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light, AppPalette.light);
  static ThemeData dark() => _build(Brightness.dark, AppPalette.dark);

  static ThemeData _build(Brightness brightness, AppPalette p) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: p.accent,
      onPrimary: p.onAccent,
      primaryContainer: p.accentSoft,
      onPrimaryContainer: p.accent,
      secondary: p.accent,
      onSecondary: p.onAccent,
      error: p.error,
      onError: p.surface,
      surface: p.surface,
      onSurface: p.ink,
      onSurfaceVariant: p.muted,
      outline: p.line,
      outlineVariant: p.line,
    );

    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final text = base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink);

    final radius = BorderRadius.circular(8);

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: p.paper,
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.45),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.paper,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        border: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide(color: p.line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide(color: p.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: p.accent, width: 1.5)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          side: BorderSide(color: p.line),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
