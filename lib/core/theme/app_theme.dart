import 'package:flutter/material.dart';

class AppTheme {
  static final darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF0D0D0D), // Pitch black / AMOLED
    cardColor: const Color(0xFF1E1B1B), // Superficie card tipica del tuo design
    colorScheme: const ColorScheme.dark(
      surface: Color(0xFF1E1B1B),
      primary: Color(0xFFE89B88), // Accento salmone/corallo
      secondary: Color(0xFF38E6C), // Verde smeraldo
      onSurface: Color(0xFFFEDE0DE),
    ),
    cardTheme: const CardThemeData(
      color: Color(0xFF1E1B1B),
      elevation: 0,
    ),
  );
}