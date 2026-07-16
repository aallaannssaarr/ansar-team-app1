import 'package:flutter/material.dart';

import 'ansar_tokens.dart';

ThemeData buildAnsarTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: brandColor,
    brightness: Brightness.light,
    primary: brandColor,
    secondary: accentColor,
    surface: panelSurface,
    error: dangerColor,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Noto Sans Arabic',
  );
  return base.copyWith(
    scaffoldBackgroundColor: softSurface,
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        color: inkColor,
        fontWeight: FontWeight.w800,
        height: 1.35,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        color: inkColor,
        fontWeight: FontWeight.w800,
        height: 1.35,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        color: inkColor,
        fontWeight: FontWeight.w700,
        height: 1.4,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(color: inkColor, height: 1.55),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(color: inkColor, height: 1.55),
      bodySmall: base.textTheme.bodySmall?.copyWith(color: mutedInk, height: 1.45),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
    ),
    appBarTheme: const AppBarThemeData(
      centerTitle: true,
      backgroundColor: panelSurface,
      foregroundColor: inkColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: inkColor,
        fontSize: 19,
        fontWeight: FontWeight.w800,
        height: 1.35,
        fontFamily: 'Noto Sans Arabic',
      ),
      iconTheme: IconThemeData(color: inkColor),
    ),
    cardTheme: const CardThemeData(
      color: panelSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(ansarRadius)),
        side: BorderSide(color: borderColor),
      ),
    ),
    dividerTheme: const DividerThemeData(color: borderColor, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: panelSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: const TextStyle(color: mutedInk),
      hintStyle: const TextStyle(color: Color(0xff899590)),
      prefixIconColor: mutedInk,
      suffixIconColor: mutedInk,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ansarRadius),
        borderSide: const BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ansarRadius),
        borderSide: const BorderSide(color: brandColor, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ansarRadius),
        borderSide: const BorderSide(color: dangerColor),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ansarRadius),
        borderSide: const BorderSide(color: dangerColor, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ansarRadius)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 50),
        foregroundColor: brandColor,
        side: const BorderSide(color: strongBorderColor),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ansarRadius)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brandColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ansarRadius)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: inkColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ansarRadius)),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: brandColor,
      foregroundColor: Colors.white,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(ansarRadius))),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 70,
      backgroundColor: panelSurface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: successSurface,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(color: states.contains(WidgetState.selected) ? brandColor : mutedInk, size: 23);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return TextStyle(
          color: states.contains(WidgetState.selected) ? brandColor : mutedInk,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
        );
      }),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: const Color(0xffF0F4F2),
      selectedColor: successSurface,
      side: const BorderSide(color: borderColor),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      labelStyle: const TextStyle(color: inkColor, fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: panelSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(ansarRadius))),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: panelSurface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(ansarRadius))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: inkColor,
      contentTextStyle: const TextStyle(color: Colors.white, height: 1.4),
      behavior: SnackBarBehavior.floating,
      elevation: 2,
      insetPadding: const EdgeInsets.all(14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ansarRadius)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: brandColor),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
