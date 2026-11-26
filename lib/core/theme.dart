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

  /// Rose-pink accent — the mockup's accent (design basis 2026-11-26,
  /// the جامع الكتب التسعة interfaces): pills, the active bottom-nav
  /// item, section-header actions and the home shortcut cards. Petrol
  /// stays the primary; pink is the accent, never a second primary and
  /// never a dominant green (there is no green in this palette at all).
  static const Color rose = Color(0xFFD95F73);

  /// Deeper rose for active labels / text on light rose surfaces.
  static const Color roseDark = Color(0xFFB84A5E);

  /// Light rose surface for the home shortcut cards (mockup screen 1).
  static const Color roseSurface = Color(0xFFFBE7E7);

  /// Pale rose fill for pills and the home quote card.
  static const Color roseSoft = Color(0xFFF6D9DC);

  /// Distinctive RED for narrator names inside a hadith text (user
  /// decision 2026-11-26 17:23 — ONE red colour for every parsed
  /// narrator name, all tappable). This is the ONLY red in the app
  /// besides the rose accent, and it is NOT a palette change: the
  /// petrol/ivory/matte-gold identity is untouched (palette decision
  /// 2026-11-26 17:26 — «أبقِ البترولي وخذ التخطيط بس»). A deep red so
  /// it reads clearly on ivory and is unmistakable next to petrol.
  static const Color narratorRed = Color(0xFFB3261E);

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

/// Shared text styles for the mockup screens (single source of truth
/// next to the colours — widgets must not re-declare these sizes).
abstract final class SunnatiText {
  /// Section header, e.g. «آخر الأحاديث» (mockup screen 1).
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.bold,
    color: SunnatiColors.ink,
  );

  /// Rose action next to a section header, e.g. «عرض الكل».
  static const TextStyle sectionAction = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.bold,
    color: SunnatiColors.roseDark,
  );

  /// Label under an icon on a home shortcut card.
  static const TextStyle cardLabel = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: SunnatiColors.ink,
  );

  /// Book title in the Nine Books list (mockup screen 2).
  static const TextStyle bookTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    color: SunnatiColors.ink,
  );

  /// Book author line under the title.
  static const TextStyle bookAuthor = TextStyle(
    fontSize: 13,
    color: SunnatiColors.inkMuted,
  );
}
