import 'package:flutter/material.dart';

/// Stessi token di grokdog/src/app/globals.css. L'app è solo scura.
abstract final class AppColors {
  static const app = Color(0xFF121212); // area principale
  static const side = Color(0xFF0E0E0E); // barre di navigazione
  static const panel = Color(0xFF1F1F1F); // card, pill, input
  static const line = Color(0xFF2A2A2A); // bordi sottili
  static const hover = Color(0xFF282828);
  static const active = Color(0xFF2E2E2E);
  static const ink = Color(0xFFF5F5F5); // testo principale
  static const muted = Color(0xFFA8A8A8); // timestamp, icone
  static const faint = Color(0xFF707070); // placeholder
  static const accent = Color(0xFFE99A3C); // arancio
  static const user = Color(0xFF3962B7); // avatar
  static const ok = Color(0xFF34D399); // connesso, batteria ok

  // i colori dei personaggi di GrokBot
  static const botColors = [Color(0xFF0BC46C), Color(0xFF1684FF), Color(0xFFFF9A00), Color(0xFFFF3EA5), Color(0xFF13BFA6)];

  // palette Tailwind usata da badge e allarmi
  static const red400 = Color(0xFFFF6467);
  static const red500 = Color(0xFFFB2C36);
  static const red600 = Color(0xFFE7000B);
  static const amber300 = Color(0xFFFFD230);
  static const emerald400 = Color(0xFF00D492);
  static const sky300 = Color(0xFF74D4FF);
  static const violet300 = Color(0xFFC4B4FF);
}

abstract final class AppText {
  static const mono = 'GeistMono';
  static const tabular = [FontFeature.tabularFigures()];

  static const body = TextStyle(fontSize: 14, height: 1.4, color: AppColors.ink);
  static const bodyMuted = TextStyle(fontSize: 14, height: 1.4, color: AppColors.muted);
  static const bodyFaint = TextStyle(fontSize: 14, height: 1.4, color: AppColors.faint);
  static const medium = TextStyle(fontSize: 14, height: 1.4, color: AppColors.ink, fontWeight: FontWeight.w500);
  static const row = TextStyle(fontSize: 15, height: 1.4, color: AppColors.ink);
  static const section = TextStyle(fontSize: 15, height: 1.4, color: AppColors.ink, fontWeight: FontWeight.w500);
  static const title = TextStyle(fontSize: 20, height: 1.3, color: AppColors.ink, fontWeight: FontWeight.w500, letterSpacing: -0.3);
  static const code = TextStyle(fontFamily: mono, fontSize: 13, height: 1.4, color: AppColors.ink, fontFeatures: tabular);
  static const codeMuted = TextStyle(fontFamily: mono, fontSize: 13, height: 1.4, color: AppColors.muted, fontFeatures: tabular);
  static const codeFaint = TextStyle(fontFamily: mono, fontSize: 13, height: 1.4, color: AppColors.faint, fontFeatures: tabular);
}

ThemeData buildTheme() {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: AppColors.line),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Geist',
    scaffoldBackgroundColor: AppColors.app,
    canvasColor: AppColors.panel,
    dividerColor: AppColors.line,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.app,
      primary: AppColors.accent,
      onPrimary: AppColors.app,
      secondary: AppColors.accent,
      onSurface: AppColors.ink,
      outline: AppColors.line,
      error: AppColors.red400,
    ),
    textTheme: const TextTheme(bodyMedium: AppText.body, bodyLarge: AppText.row, titleMedium: AppText.section),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.side,
      foregroundColor: AppColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AppText.section,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: AppColors.faint,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.panel,
      contentTextStyle: AppText.body,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.app,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      hintStyle: AppText.bodyFaint,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: const BorderSide(color: Color(0xFF3A3A3A))),
    ),
    timePickerTheme: const TimePickerThemeData(backgroundColor: AppColors.panel),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(AppColors.app),
      side: const BorderSide(color: AppColors.faint),
    ),
  );
}
