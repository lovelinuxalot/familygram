import 'package:flutter/material.dart';

// Familygram "deep ocean" palette: navy primary, ice-blue secondary, near-
// white backgrounds. Authoritative without being cold; the photos carry the
// warmth. Material 3 seeds the full tone palette from #1E3A5F; we then nudge
// the surfaces toward an even cooler near-white for editorial calm.
const _kSeed = Color(0xFF1E3A5F);

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: _kSeed, brightness: Brightness.light).copyWith(
    primary: const Color(0xFF1E3A5F),
    onPrimary: Colors.white,
    secondary: const Color(0xFF7BA9CC),
    surface: const Color(0xFFF7F9FB),
    onSurface: const Color(0xFF14202E),
    surfaceContainerHighest: const Color(0xFFEAEFF4),
  );
  return _shared(scheme);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: _kSeed, brightness: Brightness.dark).copyWith(
    primary: const Color(0xFF8BB4D6),
    onPrimary: const Color(0xFF0E1B2A),
    secondary: const Color(0xFF5C89AB),
    surface: const Color(0xFF0F1822),
    onSurface: const Color(0xFFE6ECF2),
    surfaceContainerHighest: const Color(0xFF1A2533),
  );
  return _shared(scheme);
}

ThemeData _shared(ColorScheme scheme) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
      thickness: 0.5,
      space: 0.5,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
