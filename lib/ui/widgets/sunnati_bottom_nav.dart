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

/// Selects a tab on the LIVE app shell (registered by `lib/main.dart`,
/// which owns the shell state).
///
/// Registered by the shell itself in `initState` and cleared in
/// `dispose`. The nav widget must not import `main.dart` (that would be
/// an import cycle), so the entry point hands the callback over through
/// this variable instead. Null only before the app has booted — and
/// pushed screens (the only callers of [sunnatiGoToTab]) exist solely
/// under a booted shell, so a null here means "do nothing".
ValueChanged<int>? sunnatiSelectTab;

/// Switch to tab [index] from a PUSHED screen.
///
/// Pops back to the LIVE shell (the first route) and selects the tab
/// there — the shell keeps every tab's state alive (IndexedStack), so
/// scroll positions, typed searches and the reader's place survive the
/// switch. This REPLACES the old behaviour (2026-11-26 smoothness fix
/// 1) of pushing a FRESH shell with pushAndRemoveUntil, which rebuilt
/// the whole app from scratch on every tab tap and felt like a restart.
///
/// In-shell tab switches (the shell's own `setState`) are untouched —
/// only pushed screens use this helper.
void sunnatiGoToTab(BuildContext context, int index) {
  Navigator.of(context).popUntil((route) => route.isFirst);
  sunnatiSelectTab?.call(index);
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
