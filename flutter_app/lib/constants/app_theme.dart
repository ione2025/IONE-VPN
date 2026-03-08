import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// IONE VPN design system – light and dark themes.
class AppTheme {
  AppTheme._();

  // ─── Brand colours ────────────────────────────────────────────────────────
  static const Color primaryBlue = Color(0xFF1A73E8);
  static const Color accentCyan = Color(0xFF00D2FF);
  static const Color successGreen = Color(0xFF34A853);
  static const Color errorRed = Color(0xFFEA4335);
  static const Color warningAmber = Color(0xFFFBBC04);

  // ─── Dark palette ─────────────────────────────────────────────────────────
  static const Color darkBg = Color(0xFF0D1117);
  static const Color darkSurface = Color(0xFF161B22);
  static const Color darkCard = Color(0xFF21262D);
  static const Color darkBorder = Color(0xFF30363D);

  // ─── Light palette ────────────────────────────────────────────────────────
  static const Color lightBg = Color(0xFFF6F8FA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);

  static TextTheme _textTheme(Color base) => GoogleFonts.interTextTheme(
        TextTheme(
          displayLarge: TextStyle(color: base, fontWeight: FontWeight.w700),
          headlineLarge: TextStyle(color: base, fontWeight: FontWeight.w700),
          headlineMedium: TextStyle(color: base, fontWeight: FontWeight.w600),
          titleLarge: TextStyle(color: base, fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(color: base),
          bodyMedium: TextStyle(color: base.withOpacity(0.75)),
          labelLarge: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );

  // ─── Light theme ──────────────────────────────────────────────────────────
  static final ThemeData light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryBlue,
      brightness: Brightness.light,
      background: lightBg,
      surface: lightSurface,
    ),
    scaffoldBackgroundColor: lightBg,
    textTheme: _textTheme(const Color(0xFF1C1E21)),
    appBarTheme: const AppBarTheme(
      backgroundColor: lightSurface,
      foregroundColor: Color(0xFF1C1E21),
      elevation: 0,
      centerTitle: true,
    ),
    cardTheme: CardTheme(
      color: lightCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE1E4E8)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: lightBg,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
  );

  // ─── Dark theme ───────────────────────────────────────────────────────────
  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryBlue,
      brightness: Brightness.dark,
      background: darkBg,
      surface: darkSurface,
    ),
    scaffoldBackgroundColor: darkBg,
    textTheme: _textTheme(Colors.white),
    appBarTheme: const AppBarTheme(
      backgroundColor: darkSurface,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: true,
    ),
    cardTheme: CardTheme(
      color: darkCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: darkBorder),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: darkCard,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
  );
}
