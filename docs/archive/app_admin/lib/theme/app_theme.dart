import 'package:flutter/material.dart';

/// CoEvo Material 3 Theme
/// Brand: Deep Blue + Emerald Green (进化/成长)
class AppTheme {
  // ── Spacing Tokens ──
  static const double spacingXs = 4;
  static const double spacingSm = 8;
  static const double spacingMd = 12;
  static const double spacingLg = 16;
  static const double spacingXl = 20;
  static const double spacingXxl = 24;
  static const double spacingXxxl = 32;
  static const double spacingXxxxl = 48;

  // ── Brand Colors ──
  static const Color _primaryLight = Color(0xFF1A237E);   // Deep Blue 800
  static const Color _primaryDark = Color(0xFF5C6BC0);    // Indigo 300
  static const Color _secondaryLight = Color(0xFF00C853); // Emerald Green
  static const Color _secondaryDark = Color(0xFF69F0AE);  // Green 200
  static const Color _tertiaryLight = Color(0xFFFF6F00);  // Amber 800
  static const Color _tertiaryDark = Color(0xFFFFD740);   // Amber 300

  static const Color _surfaceLight = Color(0xFFF5F5F0);
  static const Color _surfaceDark = Color(0xFF1C1B1F);
  static const Color _backgroundLight = Color(0xFFFAFAF5);
  static const Color _backgroundDark = Color(0xFF121212);

  // ── Light Theme ──
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _primaryLight,
      primary: _primaryLight,
      secondary: _secondaryLight,
      tertiary: _tertiaryLight,
      surface: _surfaceLight,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: _backgroundLight,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: -0.5),
      headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.3),
      headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.normal, height: 1.5),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.normal, height: 1.4),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.normal, height: 1.3),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.5),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.normal, letterSpacing: 0.3),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 1,
      backgroundColor: _surfaceLight,
      foregroundColor: Color(0xFF1A1A2E),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: _primaryLight, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _primaryLight,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: _secondaryLight,
      foregroundColor: Colors.white,
    ),
  );

  // ── Dark Theme ──
  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _primaryDark,
      primary: _primaryDark,
      secondary: _secondaryDark,
      tertiary: _tertiaryDark,
      surface: _surfaceDark,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: _backgroundDark,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: -0.5),
      headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.3),
      headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.normal, height: 1.5),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.normal, height: 1.4),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.normal, height: 1.3),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.5),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.normal, letterSpacing: 0.3),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 1,
      backgroundColor: _surfaceDark,
      foregroundColor: Color(0xFFE6E1E5),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade800),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF2C2C2C),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(color: Colors.grey.shade700),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(color: Colors.grey.shade700),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: _primaryDark, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _primaryDark,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: _secondaryDark,
      foregroundColor: Colors.black,
    ),
  );

  // ── Duolingo Theme (Light) ──
  // Design reference: docs/design/Duolingo/DESIGN.md
  // Key traits: flat design, Duo Green #58cc02, Fredoka+Nunito fonts, 3D button shadow

  static const Color _duoGreen = Color(0xFF58cc02);
  static const Color _duoGreenShadow = Color(0xFF3f8f01);
  static const Color _duoSkyBlue = Color(0xFF1cb0f6);
  static const Color _duoSunshine = Color(0xFFffc700);
  static const Color _duoPink = Color(0xFFcc348d);
  static const Color _duoBorder = Color(0xFFe5e5e5);
  static const Color _duoInputFill = Color(0xFFf7f7f7);

  static ThemeData get duolingo => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _duoGreen,
      primary: _duoGreen,
      secondary: _duoSkyBlue,
      tertiary: _duoSunshine,
      error: _duoPink,
      surface: Colors.white,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: Colors.white,
    textTheme: TextTheme(
      headlineLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 28, letterSpacing: 1.7),
      headlineMedium: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 24, letterSpacing: 1.5),
      headlineSmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 20, letterSpacing: 1.0),
      titleLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 18, letterSpacing: 0.8),
      titleMedium: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 16, letterSpacing: 0.8),
      titleSmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 14, letterSpacing: 0.8),
      bodyLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 16, height: 1.5, letterSpacing: 0.8),
      bodyMedium: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 14, height: 1.4, letterSpacing: 0.69),
      bodySmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 12, height: 1.3, letterSpacing: 0.53),
      labelLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 14, letterSpacing: 0.5),
      labelSmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 11, letterSpacing: 0.3),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: Colors.white,
      foregroundColor: _duoGreen,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _duoBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _duoInputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _duoBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _duoBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _duoGreen, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _duoGreen,
        foregroundColor: Colors.white,
        elevation: 4,
        shadowColor: _duoGreenShadow,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: _duoGreen,
      foregroundColor: Colors.white,
      elevation: 4,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      indicatorColor: _duoGreen.withAlpha(30),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: _duoGreen);
        }
        return IconThemeData(color: Colors.grey.shade500);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const TextStyle(
              color: _duoGreen, fontWeight: FontWeight.w700, fontSize: 12);
        }
        return TextStyle(
            color: Colors.grey.shade500, fontWeight: FontWeight.w500, fontSize: 12);
      }),
    ),
  );

  // ── Duolingo Theme (Dark) ──
  // Derived from light theme: brand colors preserved, backgrounds darkened

  static const Color _duoDarkBg = Color(0xFF1a1a1a);
  static const Color _duoDarkSurface = Color(0xFF2d2d2d);
  static const Color _duoDarkBorder = Color(0xFF404040);
  static const Color _duoDarkInputFill = Color(0xFF333333);
  static const Color _duoDarkSkyBlue = Color(0xFF4dc9f6);
  static const Color _duoDarkGreenShadow = Color(0xFF2d6f01);

  static ThemeData get duolingoDark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _duoGreen,
      primary: _duoGreen,
      secondary: _duoDarkSkyBlue,
      tertiary: _duoSunshine,
      error: _duoPink,
      surface: _duoDarkSurface,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: _duoDarkBg,
    textTheme: TextTheme(
      headlineLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 28, letterSpacing: 1.7),
      headlineMedium: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 24, letterSpacing: 1.5),
      headlineSmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 20, letterSpacing: 1.0),
      titleLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 18, letterSpacing: 0.8),
      titleMedium: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 16, letterSpacing: 0.8),
      titleSmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 14, letterSpacing: 0.8),
      bodyLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 16, height: 1.5, letterSpacing: 0.8),
      bodyMedium: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 14, height: 1.4, letterSpacing: 0.69),
      bodySmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 12, height: 1.3, letterSpacing: 0.53),
      labelLarge: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.w500,
          fontSize: 14, letterSpacing: 0.5),
      labelSmall: TextStyle(
          fontFamily: 'AlibabaPuHuiTi', fontWeight: FontWeight.normal,
          fontSize: 11, letterSpacing: 0.3),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: _duoDarkBg,
      foregroundColor: _duoGreen,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _duoDarkBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _duoDarkInputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _duoDarkBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _duoDarkBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _duoGreen, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _duoGreen,
        foregroundColor: Colors.white,
        elevation: 4,
        shadowColor: _duoDarkGreenShadow,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: _duoGreen,
      foregroundColor: Colors.white,
      elevation: 4,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: _duoDarkBg,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      indicatorColor: _duoGreen.withAlpha(40),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: _duoGreen);
        }
        return IconThemeData(color: Colors.grey.shade600);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const TextStyle(
              color: _duoGreen, fontWeight: FontWeight.w700, fontSize: 12);
        }
        return TextStyle(
            color: Colors.grey.shade600, fontWeight: FontWeight.w500, fontSize: 12);
      }),
    ),
  );
}
