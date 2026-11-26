/// Shared bottom navigation — mockup screens 1–8 (the جامع الكتب التسعة
/// interfaces the 2026-11-26 mockup reproduces).
///
/// Exactly five tabs. The tab indices are the contract used by the app
/// shell (see `lib/main.dart`):
///   0 المزيد · 1 المكتبة · 2 الرئيسية · 3 البحث · 4 الحديث
///
/// The bar is drawn in the mockup's visual order: in RTL the first child
/// of a Row sits at the right, so the children are laid out reversed —
/// الحديث at the far right, الرئيسية centred, المزيد at the far left.
/// Active item: rose-pink icon + label; inactive: grey-violet.
library;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// Builds a fresh app shell opened on the given tab index.
///
/// Registered once by the app entry point (`lib/main.dart`), which is
/// the only place that owns the database, user data and theme callbacks
/// a shell needs. The nav widget itself must not import `main.dart`
/// (that would be an import cycle), so the entry point hands the factory
/// over through this variable instead.
typedef SunnatiShellBuilder = Widget Function(int index);

/// Factory for a fresh shell, set by `lib/main.dart` on every build
/// once the library is open. Null only before the app has booted — and
/// pushed screens (the only callers of [sunnatiGoToTab]) exist solely
/// under a booted shell, so a null here means "do nothing".
SunnatiShellBuilder? sunnatiShellBuilder;

/// Switch to tab [index] from a PUSHED screen.
///
/// Replaces the whole navigation stack with a fresh shell opened on the
/// given tab ([SunnatiBottomNav] index contract: 0 المزيد، 1 المكتبة،
/// 2 الرئيسية، 3 البحث، 4 الحديث). Switching tabs from a pushed screen
/// therefore resets the back stack — the pushed page is gone and the
/// back button exits the app from the fresh shell, exactly like a
/// standard tab bar: tabs are top-level destinations, not pages stacked
/// on top of each other.
///
/// In-shell tab switches (the shell's own `setState`) are untouched —
/// only pushed screens use this helper.
void sunnatiGoToTab(BuildContext context, int index) {
  final buildShell = sunnatiShellBuilder;
  if (buildShell == null) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute<void>(builder: (_) => buildShell(index)),
    (route) => false,
  );
}

class SunnatiBottomNav extends StatelessWidget {
  const SunnatiBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  /// Active tab index: 0 المزيد، 1 المكتبة، 2 الرئيسية، 3 البحث، 4 الحديث.
  final int currentIndex;

  /// Called with the tapped tab index (same 0–4 contract).
  final ValueChanged<int> onTap;

  /// Labels in tab-index order.
  static const List<String> labels = <String>[
    'المزيد',
    'المكتبة',
    'الرئيسية',
    'البحث',
    'الحديث',
  ];

  /// Icons in tab-index order (inactive state).
  static const List<IconData> icons = <IconData>[
    Icons.more_horiz,
    Icons.library_books_outlined,
    Icons.home_outlined,
    Icons.search,
    Icons.menu_book_outlined,
  ];

  /// Icons in tab-index order (active state).
  static const List<IconData> activeIcons = <IconData>[
    Icons.more_horiz,
    Icons.library_books,
    Icons.home,
    Icons.search,
    Icons.menu_book,
  ];

  @override
  Widget build(BuildContext context) {
    // Visual order, right → left in RTL: الحديث، البحث، الرئيسية،
    // المكتبة، المزيد — exactly as the mockup draws it.
    const visualOrder = <int>[4, 3, 2, 1, 0];
    return Container(
      decoration: const BoxDecoration(
        color: SunnatiColors.ivoryCard,
        border: Border(
          top: BorderSide(color: SunnatiColors.goldSoft),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              for (final i in visualOrder)
                Expanded(
                  child: _NavItem(
                    label: labels[i],
                    icon: icons[i],
                    activeIcon: activeIcons[i],
                    active: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        active ? SunnatiColors.rose : SunnatiColors.neutral;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            active ? activeIcon : icon,
            size: 24,
            color: color,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? SunnatiColors.roseDark : SunnatiColors.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}
