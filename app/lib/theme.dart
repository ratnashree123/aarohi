import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// "Aarohi Aura" — inner light in a void. From stitch DESIGN.md.
class Aura {
  static const bg = Color(0xFF0A0A0A); // the void
  static const surface = Color(0xFF131313);
  static const surfaceLow = Color(0xFF1C1B1B);
  static const surfaceHigh = Color(0xFF2A2A2A);
  static const amber = Color(0xFFFF9500); // the glow
  static const amberSoft = Color(0xFFFFB874);
  static const amberPale = Color(0xFFFFDCBF);
  static const hearth = Color(0xFF2C1A05);
  static const outline = Color(0xFF554334);
  static const text = Color(0xFFE5E2E1);
  static const textDim = Color(0xFFA38D7A);
  static const blue = Color(0xFF8AD3FF);

  static List<BoxShadow> glow({double opacity = 0.35}) => [
        BoxShadow(
          color: amber.withValues(alpha: opacity),
          blurRadius: 20,
          spreadRadius: 1,
        ),
        BoxShadow(
          color: amber.withValues(alpha: opacity * 0.5),
          blurRadius: 80,
          spreadRadius: 4,
        ),
      ];
}

ThemeData aarohiTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Aura.bg,
    colorScheme: const ColorScheme.dark(
      primary: Aura.amber,
      onPrimary: Color(0xFF2D1600),
      secondary: Aura.amberSoft,
      surface: Aura.surface,
      onSurface: Aura.text,
      outline: Aura.outline,
    ),
    textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
      bodyColor: Aura.text,
      displayColor: Aura.text,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: Aura.amberSoft,
      elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Aura.amberSoft,
        foregroundColor: const Color(0xFF2D1600),
        minimumSize: const Size(0, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 1),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Aura.text,
        side: const BorderSide(color: Aura.outline),
        minimumSize: const Size(0, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Aura.surfaceLow,
      hintStyle: const TextStyle(color: Aura.textDim),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Aura.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Aura.amber),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Aura.surface,
      indicatorColor: Aura.hearth,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? Aura.amberSoft
              : Aura.textDim,
        ),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
    ),
  );
}
