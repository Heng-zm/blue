import 'package:flutter/material.dart';

class MgsColors {
  static const ink = Color(0xFF070B0D);
  static const panel = Color(0xFF0F171B);
  static const panelHigh = Color(0xFF162126);
  static const line = Color(0xFF223137);
  static const lime = Color(0xFFC9FF6A);
  static const mint = Color(0xFF62E6C8);
  static const text = Color(0xFFE8F1EC);
  static const muted = Color(0xFF8BA09C);
  static const danger = Color(0xFFFF6B6B);
  static const amber = Color(0xFFFFC46B);
}

ThemeData buildMgsTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: MgsColors.lime,
    brightness: Brightness.dark,
  );
  final scheme = base.copyWith(
    primary: MgsColors.lime,
    onPrimary: const Color(0xFF132000),
    primaryContainer: const Color(0xFF24330D),
    onPrimaryContainer: MgsColors.lime,
    secondary: MgsColors.mint,
    onSecondary: const Color(0xFF002019),
    secondaryContainer: const Color(0xFF102E28),
    onSecondaryContainer: MgsColors.mint,
    error: MgsColors.danger,
    errorContainer: const Color(0xFF3A1111),
    onErrorContainer: const Color(0xFFFFB4B4),
    surface: MgsColors.ink,
    onSurface: MgsColors.text,
    surfaceContainerHighest: MgsColors.panelHigh,
    onSurfaceVariant: MgsColors.muted,
    outline: MgsColors.line,
    outlineVariant: const Color(0xFF1A262B),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: MgsColors.ink,
    textTheme: const TextTheme(
      displayLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -2),
      displayMedium: TextStyle(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.5,
      ),
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleMedium: TextStyle(fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(height: 1.4),
      labelLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
    ).apply(bodyColor: MgsColors.text, displayColor: MgsColors.text),
    appBarTheme: const AppBarTheme(
      backgroundColor: MgsColors.ink,
      foregroundColor: MgsColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: MgsColors.panelHigh,
      hintStyle: const TextStyle(color: MgsColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: _border(MgsColors.line),
      enabledBorder: _border(MgsColors.line),
      focusedBorder: _border(MgsColors.lime),
      errorBorder: _border(MgsColors.danger),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: MgsColors.lime,
        foregroundColor: const Color(0xFF101A00),
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: MgsColors.lime),
    ),
    dividerTheme: const DividerThemeData(
      color: MgsColors.line,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: MgsColors.panelHigh,
      contentTextStyle: const TextStyle(color: MgsColors.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: MgsColors.lime,
      inactiveTrackColor: MgsColors.line,
      thumbColor: MgsColors.lime,
      overlayColor: Color(0x33C9FF6A),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: MgsColors.panel,
      indicatorColor: MgsColors.lime.withValues(alpha: 0.14),
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: states.contains(WidgetState.selected)
              ? MgsColors.lime
              : MgsColors.muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? MgsColors.lime
              : MgsColors.muted,
        ),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: MgsColors.lime,
    ),
  );
}

OutlineInputBorder _border(Color color) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(16),
  borderSide: BorderSide(color: color),
);

const EdgeInsets mgsPagePadding = EdgeInsets.fromLTRB(20, 8, 20, 28);
