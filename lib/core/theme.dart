/// SUNNATI visual identity — Phase 1.
///
/// CORRECTED IDENTITY (owner decision 2026-11-25, supersedes the earlier
/// emerald-green direction and the reference image's green palette):
///  - warm ivory backgrounds
///  - deep petrol blue as the primary / heading colour
///  - muted grey-violet for secondary text and neutral elements
///  - matte gold, sparingly, for limited details only
///  - pale pink only in tiny touches (faint floral corners/backgrounds)
/// No emerald / religious green is used as a primary colour anywhere.
/// The interface is modern, simple, elegant and clear — no exaggerated
/// ornamentation and no traditional Islamic-app template look. The reference
/// design's spirit is kept (open book + dome logo, the 15 screens) with
/// this new palette.
library;

import 'package:material_ui/material_ui.dart';

/// Brand colours. Hex values are the single source of truth; do not
/// re-declare them in widgets.
abstract final class SunnatiColors {
  /// Deep petrol blue — primary brand colour (headings, AppBar, buttons).
  static const Color petrol = Color(0xFF0F3B4D);

  /// Darker petrol — dark surfaces, night-mode primary.
  static const Color deepPetrol = Color(0xFF0A2A38);

  /// Petrol accent used in dark mode (lighter so it reads on dark).
  static const Color petrolLight = Color(0xFF2E7A96);

  /// Warm ivory — light-mode background.
  static const Color ivory = Color(0xFFF7F2E9);

  /// Warm ivory card surface (slightly lighter than the background).
  static const Color ivoryCard = Color(0xFFFAF6EC);

  /// Matte gold — sparing accents only (borders, book covers, highlights).
  /// Deliberately muted, never glossy.
  static const Color gold = Color(0xFFB89B5E);

  /// Soft matte-gold tint for selected chips / highlights.
  static const Color goldSoft = Color(0xFFEFE6CF);

  /// Primary ink for light mode (deep petrol-ink).
  static const Color ink = Color(0xFF1C2E36);

  /// Secondary text for light mode — muted grey-violet.
  static const Color inkMuted = Color(0xFF6E6A7A);

  /// Neutral grey-violet for borders / inactive elements.
  static const Color neutral = Color(0xFF8A8494);

  /// Pale pink — tiny touches only (faint floral corners/backgrounds).
  static const Color blush = Color(0xFFE8CFC8);

  /// Night-mode background (very dark petrol).
  static const Color nightBackground = Color(0xFF0C1F27);

  /// Night-mode card surface.
  static const Color nightCard = Color(0xFF122E3A);

  /// Night-mode primary text.
  static const Color nightInk = Color(0xFFF2EEE2);

  /// Night-mode secondary text (grey-violet, lightened for contrast).
  static const Color nightMuted = Color(0xFFA9A3B5);
}

/// App theme (light + dark). The Arabic font family is `Amiri`, downloaded
/// in CI from a documented OFL source; if the font files are absent in a
/// build environment Flutter falls back to the system font — the theme never
/// crashes on a missing font.
abstract final class SunnatiTheme {
  static const String fontFamily = 'Amiri';

  static ThemeData light({double fontScale = 1.0}) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: SunnatiColors.petrol,
        onPrimary: Colors.white,
        secondary: SunnatiColors.gold,
        surface: SunnatiColors.ivoryCard,
        onSurface: SunnatiColors.ink,
      ),
      scaffoldBackgroundColor: SunnatiColors.ivory,
      fontFamily: fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: SunnatiColors.petrol,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      cardTheme: const CardThemeData(
        color: SunnatiColors.ivoryCard,
        elevation: 1,
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      chipTheme: const ChipThemeData(
        selectedColor: SunnatiColors.goldSoft,
        backgroundColor: SunnatiColors.ivoryCard,
      ),
      dividerColor: SunnatiColors.goldSoft,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(fontSizeFactor: fontScale),
    );
  }

  static ThemeData dark({double fontScale = 1.0}) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: SunnatiColors.petrolLight,
        onPrimary: Colors.white,
        secondary: SunnatiColors.gold,
        surface: SunnatiColors.nightCard,
        onSurface: SunnatiColors.nightInk,
      ),
      scaffoldBackgroundColor: SunnatiColors.nightBackground,
      fontFamily: fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: SunnatiColors.deepPetrol,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      cardTheme: const CardThemeData(
        color: SunnatiColors.nightCard,
        elevation: 1,
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      dividerColor: const Color(0xFF24404E),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(fontSizeFactor: fontScale),
    );
  }
}
